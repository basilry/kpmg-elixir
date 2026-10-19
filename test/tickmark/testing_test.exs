defmodule Tickmark.TestingTest do
  use Tickmark.DataCase, async: true

  import Tickmark.AccountsFixtures
  import Tickmark.SchemaFixtures

  alias Tickmark.Accounts.Scope
  alias Tickmark.Repo
  alias Tickmark.Testing
  alias Tickmark.Testing.{Rules, TestRunRule}

  setup do
    preparer = user_fixture()
    engagement = insert_engagement(preparer)
    insert_member(engagement, preparer, :preparer)
    ledger_import = insert_ledger_import(engagement, preparer)
    run = insert_test_run(ledger_import, preparer, %{triage_threshold: 25})

    %{
      preparer: preparer,
      scope: Scope.for_user(preparer),
      outsider: user_scope_fixture(),
      engagement: engagement,
      ledger_import: ledger_import,
      run: run
    }
  end

  test "list_rules/0 returns registered modules in registry order" do
    assert Testing.list_rules() == Rules.all()
    assert Enum.map(Testing.list_rules(), & &1.id()) == Rules.ids()
  end

  test "run_topic/1 builds the run topic" do
    assert Testing.run_topic("abc") == "test_run:abc"
  end

  describe "list_test_runs/2" do
    test "lists runs newest first with rules preloaded", ctx do
      newer =
        insert_test_run(insert_ledger_import(ctx.engagement, ctx.preparer), ctx.preparer, %{
          started_at: DateTime.add(ctx.run.started_at, 60)
        })

      insert_rule(ctx.run, "approval_control_gap")

      assert [first, second] = Testing.list_test_runs(ctx.scope, ctx.engagement.id)
      assert first.id == newer.id
      assert second.id == ctx.run.id
      assert [%TestRunRule{rule_id: "approval_control_gap"}] = second.test_run_rules
    end

    test "is empty for a non-member", ctx do
      assert Testing.list_test_runs(ctx.outsider, ctx.engagement.id) == []
    end
  end

  describe "get_test_run!/2" do
    test "puts registry rules first and unknown ids last", ctx do
      insert_rule(ctx.run, "test_skip")
      insert_rule(ctx.run, "approval_control_gap")

      run = Testing.get_test_run!(ctx.scope, ctx.run.id)
      assert Enum.map(run.test_run_rules, & &1.rule_id) == ["approval_control_gap", "test_skip"]
    end

    test "raises the same way for non-members, unknown and malformed ids", ctx do
      assert_raise Ecto.NoResultsError, fn -> Testing.get_test_run!(ctx.outsider, ctx.run.id) end

      assert_raise Ecto.NoResultsError, fn ->
        Testing.get_test_run!(ctx.scope, Ecto.UUID.generate())
      end

      assert_raise Ecto.NoResultsError, fn -> Testing.get_test_run!(ctx.scope, "nope") end
    end
  end

  describe "subscribe_test_run/2" do
    test "subscribes a member to the run topic", ctx do
      assert :ok = Testing.subscribe_test_run(ctx.scope, ctx.run.id)
      Phoenix.PubSub.broadcast(Tickmark.PubSub, Testing.run_topic(ctx.run.id), :ping)
      assert_receive :ping
    end

    test "refuses a non-member", ctx do
      assert {:error, :forbidden} = Testing.subscribe_test_run(ctx.outsider, ctx.run.id)
    end
  end

  describe "list_findings/3 and count_findings/2" do
    setup ctx do
      high = insert_finding(ctx.run, entry(ctx, "JE-002"), %{score: 45, rule_ids: ["a", "b"]})
      tie = insert_finding(ctx.run, entry(ctx, "JE-001"), %{score: 45, rule_ids: ["a"]})
      edge = insert_finding(ctx.run, entry(ctx, "JE-003"), %{score: 25, rule_ids: ["b"]})
      minor = insert_finding(ctx.run, entry(ctx, "JE-004"), %{score: 10, rule_ids: ["a"]})
      %{high: high, tie: tie, edge: edge, minor: minor}
    end

    test "defaults to the review queue, highest score then entry number", ctx do
      findings = Testing.list_findings(ctx.scope, ctx.run.id)
      assert Enum.map(findings, & &1.id) == [ctx.tie.id, ctx.high.id, ctx.edge.id]
      assert hd(findings).journal_entry.entry_number == "JE-001"
    end

    test "filters by queue, status and rule", ctx do
      assert ids(Testing.list_findings(ctx.scope, ctx.run.id, %{queue: :minor})) == [ctx.minor.id]
      assert length(Testing.list_findings(ctx.scope, ctx.run.id, %{queue: :all})) == 4

      assert ids(Testing.list_findings(ctx.scope, ctx.run.id, %{queue: :all, rule_id: "b"})) ==
               [ctx.high.id, ctx.edge.id]

      assert Testing.list_findings(ctx.scope, ctx.run.id, %{status: :approved}) == []
    end

    test "counts both sides of the threshold", ctx do
      assert Testing.count_findings(ctx.scope, ctx.run.id) ==
               %{review_queue: 3, minor: 1, approved: 0}
    end

    test "counts approvals in the review queue only", ctx do
      insert_finding(ctx.run, entry(ctx, "JE-005"), %{score: 30, status: :approved})
      insert_finding(ctx.run, entry(ctx, "JE-006"), %{score: 5, status: :approved})

      assert Testing.count_findings(ctx.scope, ctx.run.id) ==
               %{review_queue: 4, minor: 2, approved: 1}
    end

    test "shows nothing to a non-member", ctx do
      assert Testing.list_findings(ctx.outsider, ctx.run.id) == []

      assert Testing.count_findings(ctx.outsider, ctx.run.id) ==
               %{review_queue: 0, minor: 0, approved: 0}
    end
  end

  describe "latest_run_summaries/1" do
    test "uses the newest run and that run's own threshold", ctx do
      older = set_status(ctx.run, :completed)
      insert_finding(older, entry(ctx, "JE-001"), %{score: 40})

      newer =
        ctx.ledger_import
        |> insert_test_run(ctx.preparer, %{
          triage_threshold: 30,
          started_at: DateTime.add(older.started_at, 60)
        })
        |> set_status(:completed_with_errors)

      insert_finding(newer, entry(ctx, "JE-002"), %{score: 30})
      insert_finding(newer, entry(ctx, "JE-003"), %{score: 29})

      assert Testing.latest_run_summaries(ctx.scope) == %{
               ctx.engagement.id => %{status: :completed_with_errors, review_queue: 1}
             }
    end

    test "has no review queue while the newest run is running", ctx do
      assert Testing.latest_run_summaries(ctx.scope) == %{
               ctx.engagement.id => %{status: :running, review_queue: nil}
             }
    end

    test "leaves out engagements without runs and engagements of others", ctx do
      set_status(ctx.run, :completed)
      no_runs = insert_engagement(ctx.preparer, %{client_name: "실행없음"})
      insert_member(no_runs, ctx.preparer, :preparer)

      other = user_fixture()
      others = insert_engagement(other)
      insert_member(others, other, :preparer)
      others |> insert_ledger_import(other) |> insert_test_run(other)

      assert Testing.latest_run_summaries(ctx.scope) == %{
               ctx.engagement.id => %{status: :completed, review_queue: 0}
             }

      assert Testing.latest_run_summaries(ctx.outsider) == %{}
    end
  end

  describe "get_finding!/2" do
    test "preloads ordered entry lines, run, suggestions, conclusions and reviewers", ctx do
      entry = entry(ctx, "JE-DETAIL")
      finding = insert_finding(ctx.run, entry)
      reviewer = user_fixture()
      insert_member(ctx.engagement, reviewer, :reviewer)
      second_line = insert_detail_line(entry, 2)
      first_line = insert_detail_line(entry, 1)

      newer_triage = insert_timed_triage(finding, ~U[2026-10-20 01:02:00.000000Z], "b")
      older_triage = insert_timed_triage(finding, ~U[2026-10-20 01:01:00.000000Z], "a")

      newer_conclusion =
        insert_timed_conclusion(finding, ctx.preparer, ~U[2026-10-20 01:04:00.000000Z])

      older_conclusion =
        insert_timed_conclusion(finding, ctx.preparer, ~U[2026-10-20 01:03:00.000000Z])

      decision = insert_detail_decision(finding, older_conclusion, reviewer)

      loaded = Testing.get_finding!(ctx.scope, finding.id)
      assert loaded.journal_entry.id == entry.id
      assert Enum.map(loaded.journal_entry.lines, & &1.id) == [first_line.id, second_line.id]
      assert loaded.test_run.id == ctx.run.id
      assert Enum.map(loaded.ai_triages, & &1.id) == [newer_triage.id, older_triage.id]
      assert Enum.map(loaded.conclusions, & &1.id) == [older_conclusion.id, newer_conclusion.id]
      assert Enum.all?(loaded.conclusions, &(&1.preparer.id == ctx.preparer.id))
      assert [%{id: decision_id, reviewer: %{email: email}}] = loaded.review_decisions
      assert decision_id == decision.id
      assert email == reviewer.email
      assert Testing.get_finding!(Scope.for_user(reviewer), finding.id).id == finding.id
    end

    test "raises the same error for a non-member, missing id and malformed ids", ctx do
      finding = insert_finding(ctx.run, entry(ctx, "JE-HIDDEN"))

      assert_raise Ecto.NoResultsError, fn ->
        Testing.get_finding!(ctx.outsider, finding.id)
      end

      for id <- [Ecto.UUID.generate(), "not-a-uuid", "", nil] do
        assert_raise Ecto.NoResultsError, fn -> Testing.get_finding!(ctx.scope, id) end
      end
    end
  end

  describe "list_rule_results/2" do
    test "keeps only the same run and entry and sorts by the registry", ctx do
      entry = entry(ctx, "JE-RULES")
      finding = insert_finding(ctx.run, entry)

      for rule_id <- Enum.reverse(Rules.ids()) do
        insert_detail_result(ctx.run, entry, rule_id)
      end

      insert_detail_result(ctx.run, entry(ctx, "JE-OTHER-ENTRY"), "round_amount")
      set_status(ctx.run, :completed)
      other_run = insert_test_run(ctx.ledger_import, ctx.preparer)
      insert_detail_result(other_run, entry, "round_amount")

      results = Testing.list_rule_results(ctx.scope, finding)
      assert Enum.map(results, & &1.rule_id) == Rules.ids()

      assert Enum.all?(
               results,
               &(&1.test_run_id == ctx.run.id and &1.journal_entry_id == entry.id)
             )
    end

    test "does not return hits to non-members or trust a substituted engagement id", ctx do
      entry = entry(ctx, "JE-PRIVATE")
      finding = insert_finding(ctx.run, entry)
      insert_detail_result(ctx.run, entry, "round_amount")
      assert Testing.list_rule_results(ctx.outsider, finding) == []
      other_engagement = insert_engagement(ctx.outsider.user)
      insert_member(other_engagement, ctx.outsider.user, :preparer)

      assert Testing.list_rule_results(ctx.outsider, %{
               finding
               | engagement_id: other_engagement.id
             }) == []
    end
  end

  defp insert_detail_line(entry, number) do
    Repo.insert!(%Tickmark.Ledger.JournalLine{
      journal_entry_id: entry.id,
      ledger_import_id: entry.ledger_import_id,
      line_number: number,
      account_code: "1020",
      account_name: "보통예금",
      description: "합성 전표 행",
      debit: Decimal.new("1000000")
    })
  end

  defp insert_timed_triage(finding, at, hash_char) do
    %Tickmark.Triage.AiTriage{finding_id: finding.id, inserted_at: at}
    |> Tickmark.Triage.AiTriage.changeset(
      valid_ai_triage_attrs(%{input_hash: String.duplicate(hash_char, 64)})
    )
    |> Repo.insert!()
  end

  defp insert_timed_conclusion(finding, preparer, at) do
    %Tickmark.Review.Conclusion{finding_id: finding.id, preparer_id: preparer.id, inserted_at: at}
    |> Tickmark.Review.Conclusion.changeset(%{outcome: :no_exception, comment: "증빙 확인 완료"})
    |> Repo.insert!()
  end

  defp insert_detail_decision(finding, conclusion, reviewer) do
    %Tickmark.Review.ReviewDecision{
      finding_id: finding.id,
      conclusion_id: conclusion.id,
      preparer_id: conclusion.preparer_id,
      reviewer_id: reviewer.id
    }
    |> Tickmark.Review.ReviewDecision.changeset(%{decision: :rejected, comment: "추가 확인 요청"})
    |> Repo.insert!()
  end

  defp insert_detail_result(run, entry, rule_id) do
    Repo.insert!(%Tickmark.Testing.RuleResult{
      test_run_id: run.id,
      journal_entry_id: entry.id,
      rule_id: rule_id,
      score: 10,
      reason: "합성 룰 근거"
    })
  end

  defp set_status(run, status), do: run |> Ecto.Changeset.change(status: status) |> Repo.update!()

  defp insert_rule(run, rule_id) do
    %TestRunRule{test_run_id: run.id}
    |> TestRunRule.create_changeset(%{rule_id: rule_id})
    |> Repo.insert!()
  end

  defp entry(ctx, entry_number),
    do: insert_journal_entry(ctx.ledger_import, %{entry_number: entry_number})

  defp ids(findings), do: Enum.map(findings, & &1.id)
end
