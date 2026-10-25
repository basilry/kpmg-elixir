defmodule Tickmark.ReviewDecisionBackstopRow do
  @moduledoc false
  # A plain string bypasses Ecto.Enum's dump validation so decision_valid is
  # tested in PostgreSQL through Repo.insert, not just in the application.
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "review_decisions" do
    field :finding_id, :binary_id
    field :conclusion_id, :binary_id
    field :preparer_id, :binary_id
    field :reviewer_id, :binary_id
    field :decision, :string
    field :comment, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

defmodule Tickmark.ReviewTest do
  use Tickmark.DataCase, async: true

  import Tickmark.AccountsFixtures
  import Tickmark.SchemaFixtures

  alias Tickmark.Accounts.Scope
  alias Tickmark.AuditTrail.AuditEvent
  alias Tickmark.{Engagements, Review}
  alias Tickmark.Review.{Conclusion, ReviewDecision}
  alias Tickmark.Testing.Finding

  setup do
    preparer = user_fixture()
    reviewer = user_fixture()
    engagement = insert_engagement(preparer)
    insert_member(engagement, preparer, :preparer)
    insert_member(engagement, reviewer, :reviewer)
    ledger_import = insert_ledger_import(engagement, preparer)
    entry = insert_journal_entry(ledger_import)
    run = insert_test_run(ledger_import, preparer)
    finding = insert_finding(run, entry)
    preparer_scope = Scope.for_user(preparer)
    :ok = Engagements.subscribe(preparer_scope, engagement.id)

    %{
      preparer: preparer,
      reviewer: reviewer,
      preparer_scope: preparer_scope,
      reviewer_scope: Scope.for_user(reviewer),
      engagement: engagement,
      ledger_import: ledger_import,
      entry: entry,
      run: run,
      finding: finding
    }
  end

  describe "submit_conclusion/3" do
    test "writes the conclusion, state, user event and both notifications", ctx do
      triage = insert_ai_triage(ctx.finding)

      attrs =
        conclusion_attrs(%{
          "ai_triage_id" => triage.id,
          "preparer_id" => ctx.reviewer.id,
          "finding_id" => Ecto.UUID.generate()
        })

      assert {:ok, conclusion} = Review.submit_conclusion(ctx.preparer_scope, ctx.finding, attrs)
      assert conclusion == Repo.get!(Conclusion, conclusion.id)
      assert conclusion.preparer_id == ctx.preparer.id
      assert conclusion.finding_id == ctx.finding.id
      assert conclusion.outcome == :no_exception
      assert conclusion.comment == attrs["comment"]
      assert conclusion.ai_triage_id == triage.id
      assert {_, 6} = conclusion.inserted_at.microsecond
      assert Repo.get!(Finding, ctx.finding.id).status == :concluded

      event = only_event(ctx, "conclusion.submitted", ctx.preparer)

      assert event.payload == %{
               "conclusion_id" => conclusion.id,
               "outcome" => "no_exception",
               "ai_triage_id" => triage.id,
               "entry_number" => ctx.entry.entry_number
             }

      assert_notifications(ctx, :concluded, event)
    end

    test "permits a finding below the triage threshold without an AI suggestion", ctx do
      finding = set_status(ctx.finding, :open, score: 10)

      assert {:ok, conclusion} =
               Review.submit_conclusion(ctx.preparer_scope, finding, conclusion_attrs())

      assert conclusion.ai_triage_id == nil
      assert only_event(ctx, "conclusion.submitted", ctx.preparer).payload["ai_triage_id"] == nil
    end

    test "resubmission appends a second conclusion without changing the first", ctx do
      assert {:ok, first} =
               Review.submit_conclusion(ctx.preparer_scope, ctx.finding, conclusion_attrs())

      assert {:ok, second} =
               Review.submit_conclusion(
                 ctx.preparer_scope,
                 ctx.finding,
                 conclusion_attrs(%{
                   "outcome" => "needs_follow_up",
                   "comment" => "추가 증빙을 확인해야 한다"
                 })
               )

      assert first.id != second.id
      assert Repo.get!(Conclusion, first.id) == first
      assert Repo.aggregate(Conclusion, :count) == 2
      assert Repo.get!(Finding, ctx.finding.id).status == :concluded
      assert length(events(ctx)) == 2
    end

    test "allows a rejected finding to be submitted again", ctx do
      set_status(ctx.finding, :rejected, triage_status: :succeeded)
      # The screen still holds an open finding and a stale triage status.
      assert {:ok, _} =
               Review.submit_conclusion(ctx.preparer_scope, ctx.finding, conclusion_attrs())

      event = only_event(ctx, "conclusion.submitted", ctx.preparer)
      assert_notifications(ctx, :concluded, event, :succeeded)
    end

    test "reads approved state from the DB even when the screen still says open", ctx do
      set_status(ctx.finding, :approved)

      assert {:error, :invalid_state} =
               Review.submit_conclusion(ctx.preparer_scope, ctx.finding, conclusion_attrs())

      assert_unchanged(ctx, :approved)
    end

    test "does not trust an approved state supplied by the screen", ctx do
      stale = %{ctx.finding | status: :approved}
      assert {:ok, _} = Review.submit_conclusion(ctx.preparer_scope, stale, conclusion_attrs())
    end

    test "rejects a reviewer or nonmember without an event", ctx do
      for scope <- [ctx.reviewer_scope, user_scope_fixture(), nil] do
        assert {:error, :forbidden} =
                 Review.submit_conclusion(scope, ctx.finding, conclusion_attrs())
      end

      assert_unchanged(ctx, :open)
    end

    test "uses persisted ownership even if the supplied engagement id is forged", ctx do
      outsider = user_fixture()
      own_engagement = insert_engagement(outsider)
      insert_member(own_engagement, outsider, :preparer)
      forged = %{ctx.finding | engagement_id: own_engagement.id}

      assert {:error, :forbidden} =
               Review.submit_conclusion(Scope.for_user(outsider), forged, conclusion_attrs())

      assert_unchanged(ctx, :open)
    end

    test "rejects another finding's AI suggestion without any writes or messages", ctx do
      other = insert_finding(ctx.run, insert_journal_entry(ctx.ledger_import))
      triage = insert_ai_triage(other)

      assert {:error, changeset} =
               Review.submit_conclusion(
                 ctx.preparer_scope,
                 ctx.finding,
                 conclusion_attrs(%{"ai_triage_id" => triage.id})
               )

      assert errors_on(changeset).ai_triage_id != []
      assert_unchanged(ctx, :open)
    end

    test "invalid or missing AI suggestion ids return a changeset error", ctx do
      for id <- ["not-a-uuid", Ecto.UUID.generate()] do
        assert {:error, changeset} =
                 Review.submit_conclusion(
                   ctx.preparer_scope,
                   ctx.finding,
                   conclusion_attrs(%{"ai_triage_id" => id})
                 )

        assert errors_on(changeset).ai_triage_id != []
      end

      assert_unchanged(ctx, :open)
    end

    test "requires an outcome and nonblank comment", ctx do
      for attrs <- [%{}, %{"outcome" => "exception", "comment" => "  \t\n"}] do
        assert {:error, changeset} =
                 Review.submit_conclusion(ctx.preparer_scope, ctx.finding, attrs)

        assert "can't be blank" in errors_on(changeset).comment
      end

      assert_unchanged(ctx, :open)
    end
  end

  describe "decide/4" do
    setup ctx do
      finding = set_status(ctx.finding, :concluded)
      conclusion = insert_conclusion(finding, ctx.preparer)
      %{finding: finding, conclusion: conclusion}
    end

    test "approves with persisted identities, event payload and notifications", ctx do
      attrs = %{
        "decision" => "approved",
        "preparer_id" => ctx.reviewer.id,
        "reviewer_id" => ctx.preparer.id,
        "finding_id" => Ecto.UUID.generate(),
        "conclusion_id" => Ecto.UUID.generate()
      }

      assert {:ok, decision} =
               Review.decide(ctx.reviewer_scope, ctx.finding, ctx.conclusion.id, attrs)

      assert decision == Repo.get!(ReviewDecision, decision.id)
      assert decision.preparer_id == ctx.preparer.id
      assert decision.reviewer_id == ctx.reviewer.id
      assert decision.finding_id == ctx.finding.id
      assert decision.conclusion_id == ctx.conclusion.id
      assert decision.decision == :approved
      assert decision.comment == nil
      assert {_, 6} = decision.inserted_at.microsecond
      assert Repo.get!(Finding, ctx.finding.id).status == :approved

      event = only_event(ctx, "review.approved", ctx.reviewer)

      assert event.payload == %{
               "conclusion_id" => ctx.conclusion.id,
               "review_decision_id" => decision.id,
               "entry_number" => ctx.entry.entry_number
             }

      assert_notifications(ctx, :approved, event)
    end

    test "rejects with the required comment in the decision and event", ctx do
      attrs = %{"decision" => "rejected", "comment" => "증빙과 판단 근거를 보완해 주세요"}

      assert {:ok, decision} =
               Review.decide(ctx.reviewer_scope, ctx.finding, ctx.conclusion.id, attrs)

      assert decision.preparer_id == ctx.preparer.id
      assert decision.reviewer_id == ctx.reviewer.id
      assert decision.comment == attrs["comment"]
      assert decision.decision == :rejected
      assert Repo.get!(Finding, ctx.finding.id).status == :rejected
      event = only_event(ctx, "review.rejected", ctx.reviewer)

      assert event.payload == %{
               "conclusion_id" => ctx.conclusion.id,
               "review_decision_id" => decision.id,
               "comment" => attrs["comment"],
               "entry_number" => ctx.entry.entry_number
             }

      assert_notifications(ctx, :rejected, event)
    end

    test "rejecting without a nonblank comment rolls back and broadcasts nothing", ctx do
      for comment <- [nil, "", "   ", "\t\n"] do
        assert {:error, changeset} =
                 Review.decide(ctx.reviewer_scope, ctx.finding, ctx.conclusion.id, %{
                   "decision" => "rejected",
                   "comment" => comment
                 })

        assert "can't be blank" in errors_on(changeset).comment
      end

      assert_unchanged(ctx, :concluded, 1)
    end

    test "requires a supported decision", ctx do
      for attrs <- [%{}, %{"decision" => "pending"}] do
        assert {:error, changeset} =
                 Review.decide(ctx.reviewer_scope, ctx.finding, ctx.conclusion.id, attrs)

        assert errors_on(changeset).decision != []
      end

      assert_unchanged(ctx, :concluded, 1)
    end

    test "reads non-concluded states again under the lock before checking the id", ctx do
      for status <- [:open, :rejected, :approved] do
        set_status(ctx.finding, status)

        assert {:error, :invalid_state} =
                 Review.decide(ctx.reviewer_scope, ctx.finding, "invalid", %{
                   "decision" => "approved"
                 })

        assert_unchanged(ctx, status, 1)
      end
    end

    test "rejects a stale conclusion and leaves both versions intact", ctx do
      newer = insert_conclusion(ctx.finding, ctx.preparer, %{comment: "새로운 판단 근거"})

      assert {:error, :stale} =
               Review.decide(ctx.reviewer_scope, ctx.finding, ctx.conclusion.id, %{
                 "decision" => "approved"
               })

      assert_unchanged(ctx, :concluded, 2)

      assert {:ok, decision} =
               Review.decide(ctx.reviewer_scope, ctx.finding, newer.id, %{
                 "decision" => "approved"
               })

      assert decision.conclusion_id == newer.id
    end

    test "malformed, missing and unrelated conclusion ids are stale", ctx do
      other_finding = insert_finding(ctx.run, insert_journal_entry(ctx.ledger_import))
      other = insert_conclusion(other_finding, ctx.preparer)

      for id <- ["not-a-uuid", nil, Ecto.UUID.generate(), other.id] do
        assert {:error, :stale} =
                 Review.decide(ctx.reviewer_scope, ctx.finding, id, %{"decision" => "approved"})
      end

      assert_unchanged(ctx, :concluded, 2)
    end

    test "orders identical conclusion timestamps by descending id", ctx do
      timestamp = DateTime.add(ctx.conclusion.inserted_at, 1, :second)
      low_id = "00000000-0000-4000-8000-000000000001"
      high_id = "ffffffff-ffff-4fff-bfff-ffffffffffff"

      for id <- [high_id, low_id] do
        %Conclusion{finding_id: ctx.finding.id, preparer_id: ctx.preparer.id}
        |> change(id: id, inserted_at: timestamp, outcome: :exception, comment: "같은 시각 제출")
        |> Repo.insert!()
      end

      assert {:error, :stale} =
               Review.decide(ctx.reviewer_scope, ctx.finding, low_id, %{"decision" => "approved"})

      assert {:ok, decision} =
               Review.decide(ctx.reviewer_scope, ctx.finding, high_id, %{"decision" => "approved"})

      assert decision.conclusion_id == high_id
    end

    test "records a preparer's forbidden attempt with reason role", ctx do
      assert {:error, :forbidden} =
               Review.decide(ctx.preparer_scope, ctx.finding, ctx.conclusion.id, %{
                 "decision" => "approved"
               })

      assert_denied(ctx, ctx.preparer, "role", "approved")
    end

    test "a malformed attempted decision is recorded as null", ctx do
      assert {:error, :forbidden} =
               Review.decide(ctx.preparer_scope, ctx.finding, ctx.conclusion.id, %{
                 "decision" => "unexpected"
               })

      assert_denied(ctx, ctx.preparer, "role", nil)
    end

    test "nonmembers are forbidden without an audit event", ctx do
      for scope <- [user_scope_fixture(), nil] do
        assert {:error, :forbidden} =
                 Review.decide(scope, ctx.finding, ctx.conclusion.id, %{"decision" => "approved"})
      end

      assert_unchanged(ctx, :concluded, 1)
    end

    test "a reviewer cannot review a conclusion they prepared before a role change", ctx do
      own = insert_conclusion(ctx.finding, ctx.reviewer)

      assert {:error, :self_review} =
               Review.decide(ctx.reviewer_scope, ctx.finding, own.id, %{
                 "decision" => "rejected",
                 "comment" => "재검토"
               })

      assert_denied(ctx, ctx.reviewer, "self_review", "rejected")
      assert Repo.get!(Conclusion, own.id) == own
    end

    test "staleness takes precedence over self-review", ctx do
      own = insert_conclusion(ctx.finding, ctx.reviewer)
      insert_conclusion(ctx.finding, ctx.preparer)

      assert {:error, :stale} =
               Review.decide(ctx.reviewer_scope, ctx.finding, own.id, %{"decision" => "approved"})

      assert_unchanged(ctx, :concluded, 3)
    end

    test "a second decision on the same conclusion is invalid even with a stale struct", ctx do
      assert {:ok, _} =
               Review.decide(ctx.reviewer_scope, ctx.finding, ctx.conclusion.id, %{
                 "decision" => "approved"
               })

      event = only_event(ctx, "review.approved", ctx.reviewer)
      assert_notifications(ctx, :approved, event)

      assert {:error, :invalid_state} =
               Review.decide(ctx.reviewer_scope, ctx.finding, ctx.conclusion.id, %{
                 "decision" => "rejected",
                 "comment" => "늦은 반려"
               })

      assert Repo.aggregate(ReviewDecision, :count) == 1
      assert events(ctx) == [event]
      refute_received {:finding_updated, _}
      refute_received {:audit_appended, _}
    end
  end

  describe "database backstops, bypassing the Review context" do
    setup ctx do
      %{conclusion: insert_conclusion(ctx.finding, ctx.preparer)}
    end

    test "reviewer_not_preparer rejects self-review", ctx do
      ctx
      |> decision_row()
      |> change(reviewer_id: ctx.preparer.id)
      |> check_constraint(:reviewer_id, name: :reviewer_not_preparer)
      |> assert_constraint(:reviewer_id, "reviewer_not_preparer")
    end

    test "the composite foreign key rejects a forged preparer", ctx do
      forged_preparer = user_fixture()

      ctx
      |> decision_row()
      |> change(preparer_id: forged_preparer.id)
      |> foreign_key_constraint(:conclusion_id, name: :review_decisions_conclusion_id_fkey)
      |> assert_constraint(:conclusion_id, "review_decisions_conclusion_id_fkey")
    end

    test "comment_required_on_reject rejects null, empty and space-only comments", ctx do
      for comment <- [nil, "", "   "] do
        ctx
        |> decision_row()
        |> change(decision: :rejected, comment: comment)
        |> check_constraint(:comment, name: :comment_required_on_reject)
        |> assert_constraint(:comment, "comment_required_on_reject")
      end
    end

    test "decision_valid rejects a value even without enum casting", ctx do
      %Tickmark.ReviewDecisionBackstopRow{
        finding_id: ctx.finding.id,
        conclusion_id: ctx.conclusion.id,
        preparer_id: ctx.preparer.id,
        reviewer_id: ctx.reviewer.id,
        decision: "pending",
        comment: "유효하지 않은 결정"
      }
      |> change()
      |> check_constraint(:decision, name: :decision_valid)
      |> assert_constraint(:decision, "decision_valid")
    end

    test "the unique conclusion index prevents two decisions", ctx do
      Repo.insert!(decision_row(ctx))

      ctx
      |> decision_row()
      |> change()
      |> unique_constraint(:conclusion_id)
      |> assert_constraint(:conclusion_id, "review_decisions_conclusion_id_index")
    end
  end

  test "missing or malformed findings are forbidden without events", ctx do
    for id <- [Ecto.UUID.generate(), "not-a-uuid", nil] do
      missing = %{ctx.finding | id: id}

      assert {:error, :forbidden} =
               Review.submit_conclusion(ctx.preparer_scope, missing, conclusion_attrs())

      assert {:error, :forbidden} =
               Review.decide(ctx.reviewer_scope, missing, Ecto.UUID.generate(), %{
                 "decision" => "approved"
               })
    end

    assert_unchanged(ctx, :open)
  end

  defp conclusion_attrs(attrs \\ %{}) do
    Map.merge(%{"outcome" => "no_exception", "comment" => "합성 증빙 대사 완료"}, attrs)
  end

  defp set_status(finding, status, attrs \\ []) do
    finding |> change([{:status, status} | attrs]) |> Repo.update!()
  end

  defp events(ctx) do
    Repo.all(from e in AuditEvent, where: e.engagement_id == ^ctx.engagement.id, order_by: e.seq)
  end

  defp only_event(ctx, action, user) do
    assert [event] = events(ctx)
    assert event.action == action
    assert event.actor_type == :user
    assert event.actor_id == user.id
    assert event.subject_type == "finding"
    assert event.subject_id == ctx.finding.id
    event
  end

  defp assert_notifications(ctx, status, event, triage_status \\ :none) do
    finding_id = ctx.finding.id

    assert_receive {:finding_updated,
                    %{finding_id: ^finding_id, status: ^status, triage_status: ^triage_status}}

    assert_audit_notification(ctx, event)
    refute_received {:finding_updated, _}
  end

  defp assert_audit_notification(ctx, event) do
    expected = %{
      seq: event.seq,
      action: event.action,
      actor_type: :user,
      subject_type: "finding",
      subject_id: ctx.finding.id,
      entry_number: ctx.entry.entry_number
    }

    assert_receive {:audit_appended, ^expected}
    refute_received {:audit_appended, _}
  end

  defp assert_unchanged(ctx, status, conclusion_count \\ 0) do
    assert Repo.get!(Finding, ctx.finding.id).status == status
    assert Repo.aggregate(Conclusion, :count) == conclusion_count
    assert Repo.aggregate(ReviewDecision, :count) == 0
    assert events(ctx) == []
    refute_received {:finding_updated, _}
    refute_received {:audit_appended, _}
  end

  defp assert_denied(ctx, user, reason, attempted) do
    event = only_event(ctx, "review.denied", user)

    assert event.payload == %{
             "reason" => reason,
             "attempted" => attempted,
             "entry_number" => ctx.entry.entry_number
           }

    assert Repo.get!(Finding, ctx.finding.id).status == :concluded
    assert Repo.aggregate(ReviewDecision, :count) == 0
    assert_audit_notification(ctx, event)
    refute_received {:finding_updated, _}
  end

  defp decision_row(ctx) do
    %ReviewDecision{
      finding_id: ctx.finding.id,
      conclusion_id: ctx.conclusion.id,
      preparer_id: ctx.preparer.id,
      reviewer_id: ctx.reviewer.id,
      decision: :approved
    }
  end

  defp assert_constraint(changeset, field, name) do
    assert changeset.valid?
    assert {:error, rejected} = Repo.insert(changeset, mode: :savepoint)
    assert {_message, opts} = Keyword.fetch!(rejected.errors, field)
    assert opts[:constraint_name] == name
  end
end
