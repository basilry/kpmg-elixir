defmodule Tickmark.AuditTrailTest do
  use Tickmark.DataCase, async: true

  import Tickmark.AccountsFixtures
  import Tickmark.SchemaFixtures

  alias Ecto.Multi
  alias Tickmark.AuditTrail
  alias Tickmark.AuditTrail.AuditEvent

  setup do
    scope = user_scope_fixture()
    %{scope: scope, engagement: insert_engagement(scope.user)}
  end

  defp event_attrs(scope, engagement, attrs \\ %{}) do
    Enum.into(attrs, %{
      engagement_id: engagement.id,
      actor: AuditTrail.actor(scope),
      action: "engagement.created",
      subject_type: "engagement",
      subject_id: engagement.id,
      payload: %{"client_name" => engagement.client_name}
    })
  end

  test "actor/1 identifies the scope's user", %{scope: scope} do
    assert AuditTrail.actor(scope) == {:user, scope.user.id}
  end

  describe "append/3" do
    test "inserts the event in the same transaction and returns seq", %{
      scope: scope,
      engagement: engagement
    } do
      {:ok, %{member: member, audit: event}} =
        Multi.new()
        |> Multi.insert(
          :member,
          Tickmark.Engagements.Member.changeset(
            %Tickmark.Engagements.Member{engagement_id: engagement.id, user_id: scope.user.id},
            %{role: :preparer}
          )
        )
        |> AuditTrail.append(:audit, fn %{member: member} ->
          event_attrs(scope, engagement, %{
            action: "engagement.member_added",
            payload: %{"member_id" => member.id, "role" => "preparer"}
          })
        end)
        |> Repo.transact()

      assert is_integer(event.seq)
      assert event.actor_type == :user
      assert event.actor_id == scope.user.id
      assert event.payload == %{"member_id" => member.id, "role" => "preparer"}
    end

    test "rolls back with the rest of the Multi", %{scope: scope, engagement: engagement} do
      {:error, :boom, :failed, _} =
        Multi.new()
        |> AuditTrail.append(:audit, fn _ -> event_attrs(scope, engagement) end)
        |> Multi.run(:boom, fn _repo, _ -> {:error, :failed} end)
        |> Repo.transact()

      assert Repo.aggregate(AuditEvent, :count) == 0
    end
  end

  describe "record/1" do
    test "assigns increasing seq values", %{scope: scope, engagement: engagement} do
      {:ok, first} = AuditTrail.record(event_attrs(scope, engagement))
      {:ok, second} = AuditTrail.record(event_attrs(scope, engagement))

      assert second.seq > first.seq
    end

    test "accepts agent and system actors without an engagement", %{engagement: engagement} do
      attrs = %{
        engagement_id: nil,
        action: "ai_triage.completed",
        subject_type: "finding",
        subject_id: engagement.id
      }

      assert {:ok, %{actor_type: :agent, actor_id: "triage:claude-opus-5-5"}} =
               AuditTrail.record(Map.put(attrs, :actor, {:agent, "triage:claude-opus-5-5"}))

      assert {:ok, %{actor_type: :system}} =
               AuditTrail.record(Map.put(attrs, :actor, {:system, "ledger.import_worker"}))
    end

    test "rejects atom payload keys and malformed actions", %{
      scope: scope,
      engagement: engagement
    } do
      {:error, changeset} =
        AuditTrail.record(event_attrs(scope, engagement, %{payload: %{client_name: "x"}}))

      assert "keys must be strings" in errors_on(changeset).payload

      {:error, changeset} =
        AuditTrail.record(event_attrs(scope, engagement, %{action: "Created"}))

      assert errors_on(changeset).action != []
    end
  end

  describe "broadcast_appended/1" do
    test "sends the event summary to the engagement topic", %{
      scope: scope,
      engagement: engagement
    } do
      :ok = Phoenix.PubSub.subscribe(Tickmark.PubSub, Tickmark.Engagements.topic(engagement.id))

      {:ok, event} =
        AuditTrail.record(
          event_attrs(scope, engagement, %{
            action: "conclusion.submitted",
            subject_type: "finding",
            payload: %{"entry_number" => "JE-000123", "outcome" => "exception"}
          })
        )

      assert :ok = AuditTrail.broadcast_appended(event)

      assert_receive {:audit_appended,
                      %{
                        seq: seq,
                        action: "conclusion.submitted",
                        actor_type: :user,
                        subject_type: "finding",
                        subject_id: subject_id,
                        entry_number: "JE-000123"
                      }}

      assert seq == event.seq
      assert subject_id == engagement.id
    end

    test "leaves entry_number nil when the payload has none and skips events without an engagement",
         %{scope: scope, engagement: engagement} do
      :ok = Phoenix.PubSub.subscribe(Tickmark.PubSub, Tickmark.Engagements.topic(engagement.id))

      {:ok, event} = AuditTrail.record(event_attrs(scope, engagement))
      assert :ok = AuditTrail.broadcast_appended(event)
      assert_receive {:audit_appended, %{action: "engagement.created", entry_number: nil}}

      {:ok, orphan} =
        AuditTrail.record(%{
          engagement_id: nil,
          actor: {:system, "testing.rule_worker"},
          action: "test_run.completed",
          subject_type: "test_run",
          subject_id: engagement.id,
          payload: %{}
        })

      assert :ok = AuditTrail.broadcast_appended(orphan)
      refute_receive {:audit_appended, _}, 50
    end
  end

  describe "list_events/3" do
    setup %{scope: scope, engagement: engagement} do
      insert_member(engagement, scope.user, :preparer)
      :ok
    end

    test "sorts by descending seq", ctx do
      first = record_event(ctx)
      second = record_event(ctx)
      assert event_seqs(ctx) == [second.seq, first.seq]
    end

    test "defaults to 50 rows and clamps limits to 1..200", ctx do
      events = Enum.map(1..205, fn _ -> record_event(ctx) end)
      seqs = events |> Enum.map(& &1.seq) |> Enum.reverse()

      assert event_seqs(ctx) == Enum.take(seqs, 50)
      assert event_seqs(ctx, limit: 10) == Enum.take(seqs, 10)
      assert event_seqs(ctx, limit: 500) == Enum.take(seqs, 200)
      assert event_seqs(ctx, limit: 0) == Enum.take(seqs, 1)
      assert event_seqs(ctx, limit: -10) == Enum.take(seqs, 1)
      assert event_seqs(ctx, limit: "10") == Enum.take(seqs, 50)
    end

    test "before_seq is exclusive and can page back to the beginning", ctx do
      first = record_event(ctx)
      second = record_event(ctx)
      third = record_event(ctx)

      assert event_seqs(ctx, before_seq: third.seq, limit: 1) == [second.seq]
      assert event_seqs(ctx, before_seq: second.seq) == [first.seq]
      assert event_seqs(ctx, before_seq: first.seq) == []
    end

    test "filters each actor type", ctx do
      person = record_event(ctx)
      agent = record_event(ctx, actor: {:agent, "triage:fake-triage-v1"})
      system = record_event(ctx, actor: {:system, "testing.rule_worker"})

      assert event_seqs(ctx, actor_type: :user) == [person.seq]
      assert event_seqs(ctx, actor_type: :agent) == [agent.seq]
      assert event_seqs(ctx, actor_type: :system) == [system.seq]
    end

    test "subject matches both the type and the uuid", ctx do
      id = Ecto.UUID.generate()
      selected = record_event(ctx, subject_type: "finding", subject_id: id)
      record_event(ctx, subject_type: "test_run", subject_id: id)
      record_event(ctx, subject_type: "finding", subject_id: Ecto.UUID.generate())

      assert event_seqs(ctx, subject: {"finding", id}) == [selected.seq]
    end

    test "entry_number matches the payload literally across different finding ids", ctx do
      selected =
        for _ <- 1..2 do
          record_event(ctx,
            subject_type: "finding",
            subject_id: Ecto.UUID.generate(),
            payload: %{"entry_number" => "JE-000123"}
          )
        end

      record_event(ctx, payload: %{"entry_number" => "JE-123"})
      record_event(ctx, payload: %{})

      assert event_seqs(ctx, entry_number: "JE-000123") ==
               selected |> Enum.map(& &1.seq) |> Enum.reverse()

      literal = record_event(ctx, payload: %{"entry_number" => "x' OR '1'='1"})
      assert event_seqs(ctx, entry_number: "x' OR '1'='1") == [literal.seq]
    end

    test "combines all filters with AND before applying the limit", ctx do
      attrs = [
        actor: {:agent, "triage:fake-triage-v1"},
        subject_type: "finding",
        subject_id: Ecto.UUID.generate(),
        payload: %{"entry_number" => "JE-000123"}
      ]

      older = record_event(ctx, attrs)
      selected = record_event(ctx, attrs)
      cutoff = record_event(ctx, attrs)
      record_event(ctx, Keyword.put(attrs, :actor, AuditTrail.actor(ctx.scope)))
      record_event(ctx, Keyword.put(attrs, :subject_type, "test_run"))
      record_event(ctx, Keyword.put(attrs, :payload, %{"entry_number" => "JE-999999"}))

      filters = [
        actor_type: :agent,
        subject: {"finding", attrs[:subject_id]},
        entry_number: "JE-000123",
        before_seq: cutoff.seq,
        limit: 1
      ]

      assert event_seqs(ctx, filters) == [selected.seq]
      assert older.seq < selected.seq
    end

    test "ignores unknown options and invalid values", ctx do
      event = record_event(ctx)

      for option <- [
            {:unknown, true},
            {:actor_type, "user"},
            {:actor_type, :nobody},
            {:before_seq, "1"},
            {:subject, {"finding", "not-a-uuid"}},
            {:subject, {"", ctx.engagement.id}},
            {:subject, :finding},
            {:entry_number, 123},
            {:entry_number, ""}
          ] do
        assert event_seqs(ctx, [option]) == [event.seq]
      end
    end

    test "non-members, missing and malformed ids get an empty list", ctx do
      record_event(ctx)
      outsider = user_scope_fixture()

      assert AuditTrail.list_events(outsider, ctx.engagement.id, []) == []
      assert AuditTrail.list_events(ctx.scope, Ecto.UUID.generate(), []) == []
      assert AuditTrail.list_events(ctx.scope, "not-a-uuid", []) == []
      assert AuditTrail.list_events(ctx.scope, nil, []) == []
      assert AuditTrail.list_events(nil, ctx.engagement.id, []) == []
    end

    test "only includes this engagement and is equally visible to reviewers", ctx do
      selected = record_event(ctx)
      other = insert_engagement(ctx.scope.user)
      insert_member(other, ctx.scope.user, :preparer)
      {:ok, _other_event} = AuditTrail.record(event_attrs(ctx.scope, other))
      record_event(ctx, engagement_id: nil)
      reviewer = user_scope_fixture()
      insert_member(ctx.engagement, reviewer.user, :reviewer)

      assert event_seqs(ctx) == [selected.seq]

      assert AuditTrail.list_events(reviewer, ctx.engagement.id, []) |> Enum.map(& &1.seq) ==
               [selected.seq]
    end
  end

  defp record_event(ctx, attrs \\ []) do
    {:ok, event} = AuditTrail.record(event_attrs(ctx.scope, ctx.engagement, attrs))
    event
  end

  defp event_seqs(ctx, opts \\ []) do
    AuditTrail.list_events(ctx.scope, ctx.engagement.id, opts) |> Enum.map(& &1.seq)
  end

  describe "seq is never written by the app" do
    test "a seq set on the struct is ignored and the DB assigns its own", %{
      scope: scope,
      engagement: engagement
    } do
      {:ok, real} = AuditTrail.record(event_attrs(scope, engagement))

      forged =
        Repo.insert!(%AuditEvent{
          seq: 1,
          actor_type: :user,
          actor_id: scope.user.id,
          action: "engagement.created",
          subject_type: "engagement",
          subject_id: engagement.id
        })

      assert forged.seq > real.seq
    end
  end

  # Each test ends with the failing statement, because a raised error aborts
  # the sandbox transaction for any later query in the same test.
  describe "DB triggers reject mutation" do
    setup %{scope: scope, engagement: engagement} do
      {:ok, event} = AuditTrail.record(event_attrs(scope, engagement))
      %{event: event}
    end

    test "UPDATE", %{event: event} do
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.update_all(where(AuditEvent, id: ^event.id), set: [action: "engagement.edited"])
        end

      assert error.postgres.message =~ "append-only table audit_events: UPDATE"
    end

    test "DELETE", %{event: event} do
      error = assert_raise Postgrex.Error, fn -> Repo.delete!(event) end
      assert error.postgres.message =~ "append-only table audit_events: DELETE"
    end
  end
end
