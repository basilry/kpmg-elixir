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

    test "TRUNCATE" do
      error = assert_raise Postgrex.Error, fn -> Repo.query!("TRUNCATE audit_events") end
      assert error.postgres.message =~ "append-only table audit_events: TRUNCATE"
    end
  end
end
