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
      assert Testing.count_findings(ctx.scope, ctx.run.id) == %{review_queue: 3, minor: 1}
    end

    test "shows nothing to a non-member", ctx do
      assert Testing.list_findings(ctx.outsider, ctx.run.id) == []
      assert Testing.count_findings(ctx.outsider, ctx.run.id) == %{review_queue: 0, minor: 0}
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
