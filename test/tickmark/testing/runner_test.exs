defmodule Tickmark.Testing.RunnerTest do
  use Tickmark.DataCase, async: true
  use Oban.Testing, repo: Tickmark.Repo

  import ExUnit.CaptureLog
  import Tickmark.AccountsFixtures
  import Tickmark.SchemaFixtures

  alias Tickmark.Accounts.Scope
  alias Tickmark.AuditTrail.AuditEvent
  alias Tickmark.Engagements
  alias Tickmark.Ledger.LedgerImport
  alias Tickmark.Testing
  alias Tickmark.Testing.{Finding, RuleResult, Rules, RuleWorker, TestRun, TestRunRule}

  @moduletag :capture_log
  @rule "approval_control_gap"

  setup do
    preparer = user_fixture()
    engagement = insert_engagement(preparer)
    insert_member(engagement, preparer, :preparer)
    ledger_import = insert_succeeded_import(engagement, preparer)

    entries =
      Enum.map(["JE-001", "JE-002"], &insert_journal_entry(ledger_import, %{entry_number: &1}))

    %{
      preparer: preparer,
      scope: Scope.for_user(preparer),
      outsider: user_scope_fixture(),
      engagement: engagement,
      ledger_import: ledger_import,
      entries: entries
    }
  end

  describe "start_test_run/3" do
    test "refuses a non-member", ctx do
      assert {:error, :forbidden} =
               Testing.start_test_run(ctx.outsider, ctx.ledger_import, [@rule])
    end

    test "re-reads the import and refuses one that is not loaded", ctx do
      pending = insert_ledger_import(ctx.engagement, ctx.preparer)
      stale = %{pending | status: :succeeded}

      assert {:error, :import_not_ready} = Testing.start_test_run(ctx.scope, stale, [@rule])
      assert all_enqueued(worker: RuleWorker) == []
    end

    test "allows one running run per import", ctx do
      assert {:ok, _run} = Testing.start_test_run(ctx.scope, ctx.ledger_import, [@rule])

      assert {:error, :run_in_progress} =
               Testing.start_test_run(ctx.scope, ctx.ledger_import, [@rule])

      assert length(all_enqueued(worker: RuleWorker)) == 1
    end

    test "raises for an empty list, an unknown id and a duplicate id", ctx do
      for rule_ids <- [[], ["nope"], [@rule, "nope"], [@rule, @rule]] do
        assert_raise ArgumentError, fn ->
          Testing.start_test_run(ctx.scope, ctx.ledger_import, rule_ids)
        end
      end

      assert Repo.aggregate(TestRun, :count) == 0
    end

    test ":all runs every registered rule and queues one job per rule", ctx do
      assert {:ok, run} = Testing.start_test_run(ctx.scope, ctx.ledger_import, :all)

      assert run.status == :running
      assert run.rule_count == length(Rules.ids())
      assert run.triage_threshold == 25
      assert run.started_by_id == ctx.preparer.id
      assert run.started_at

      rules = Repo.all(from x in TestRunRule, where: x.test_run_id == ^run.id)
      assert Enum.sort(Enum.map(rules, & &1.rule_id)) == Enum.sort(Rules.ids())
      assert Enum.all?(rules, &(&1.status == :queued and &1.hit_count == 0))

      jobs = all_enqueued(worker: RuleWorker)
      assert length(jobs) == length(Rules.ids())
      assert Enum.sort(Enum.map(jobs, & &1.args["rule_id"])) == Enum.sort(Rules.ids())
      assert Enum.all?(jobs, &(&1.args["test_run_id"] == run.id and &1.queue == "rules"))
    end

    test "snapshots each rule's default params", ctx do
      run = start(ctx, [@rule, "test_skip"])
      {:ok, module} = Rules.fetch(@rule)

      params =
        Repo.all(
          from x in TestRunRule,
            where: x.test_run_id == ^run.id,
            select: {x.rule_id, x.params}
        )

      assert Map.new(params) == %{@rule => module.default_params(), "test_skip" => %{}}
    end

    test "writes one audit event and broadcasts once the run is committed", ctx do
      subscribe_engagement(ctx)
      run = start(ctx, [@rule])
      run_id = run.id

      assert [event] = audit_events(run)
      assert event.action == "test_run.started"
      assert event.actor_type == :user
      assert event.actor_id == ctx.preparer.id
      assert event.engagement_id == ctx.engagement.id
      assert event.subject_type == "test_run"
      assert event.subject_id == run.id

      assert event.payload == %{
               "ledger_import_id" => ctx.ledger_import.id,
               "rule_ids" => [@rule],
               "triage_threshold" => 25
             }

      assert_receive {:test_run_updated, message}
      assert message == %{test_run_id: run_id, status: :running, finding_count: 0}
      refute_receive {:test_run_updated, _}
    end

    test "broadcasts nothing when the insert fails", ctx do
      subscribe_engagement(ctx)
      start(ctx, [@rule])
      assert_receive {:test_run_updated, _}

      assert {:error, :run_in_progress} =
               Testing.start_test_run(ctx.scope, ctx.ledger_import, [@rule])

      refute_receive {:test_run_updated, _}
    end
  end

  describe "run_rule/2" do
    test "stores the hits, finishes the rule and completes a one-rule run", ctx do
      run = start(ctx, [@rule])
      assert {:ok, :done} = Testing.run_rule(run.id, @rule)

      results = results(run)
      assert length(results) == 2
      assert Enum.all?(results, &(&1.rule_id == @rule and &1.score == 25))
      assert ids(results, :journal_entry_id) == ids(ctx.entries, :id)
      assert %{"gap" => "missing_approver"} = hd(results).details

      rule = get_rule(run, @rule)
      assert rule.status == :succeeded
      assert rule.hit_count == 2
      assert rule.error == nil
      assert rule.started_at
      assert rule.finished_at

      assert %{status: :completed, finding_count: 2, finished_at: %DateTime{}} = get_run(run)

      findings = findings(run)
      assert length(findings) == 2
      assert ids(findings, :journal_entry_id) == ids(ctx.entries, :id)

      assert Enum.all?(findings, fn finding ->
               finding.engagement_id == ctx.engagement.id and finding.hit_count == 1 and
                 finding.score == 25 and finding.rule_ids == [@rule] and
                 finding.status == :open and finding.triage_status == :none
             end)

      assert [_started, completed] = audit_events(run)
      assert completed.action == "test_run.completed"
      assert completed.actor_type == :system
      assert completed.actor_id == "testing.rule_worker"
      assert completed.payload == %{"status" => "completed", "finding_count" => 2}
    end

    test "the last rule builds one finding per entry, caps the score and sorts the ids", ctx do
      [first, second] = ctx.entries
      run = insert_test_run(ctx.ledger_import, ctx.preparer, %{rule_count: 3})
      insert_queued_rule(run, @rule)
      insert_done_rule(run, "zeta", [{first, 90}])
      insert_done_rule(run, "alpha_rule", [{first, 60}])

      assert {:ok, :done} = Testing.run_rule(run.id, @rule)

      assert [top, other] = findings(run)
      assert top.journal_entry_id == first.id
      assert top.hit_count == 3
      assert top.score == 100
      assert top.rule_ids == ["alpha_rule", @rule, "zeta"]
      assert other.journal_entry_id == second.id
      assert other.hit_count == 1
      assert other.score == 25
      assert other.rule_ids == [@rule]
      assert %{status: :completed, finding_count: 2} = get_run(run)
    end

    test "records a skip with its reason and completes the run", ctx do
      run = start(ctx, ["test_skip"])
      assert {:ok, :skipped} = Testing.run_rule(run.id, "test_skip")

      rule = get_rule(run, "test_skip")
      assert rule.status == :skipped
      assert rule.hit_count == 0
      assert rule.error == "테스트용 건너뜀"
      assert rule.finished_at

      assert %{status: :completed, finding_count: 0} = get_run(run)
      assert results(run) == []
      assert actions(run) == ["test_run.started", "test_run.completed"]
    end

    test "leaves the rule running when it returns an error, so the job can retry", ctx do
      run = start(ctx, ["test_error"])
      assert {:error, :test_error} = Testing.run_rule(run.id, "test_error")

      rule = get_rule(run, "test_error")
      assert rule.status == :running
      assert rule.started_at
      assert rule.finished_at == nil
      assert rule.error == nil
      assert %{status: :running, finding_count: 0} = get_run(run)
      assert results(run) == []
      assert actions(run) == ["test_run.started"]

      assert {:error, :test_error} = Testing.run_rule(run.id, "test_error")
      assert get_rule(run, "test_error").started_at == rule.started_at
    end

    test "does not catch a rule that raises", ctx do
      run = start(ctx, ["test_raise"])

      assert_raise RuntimeError, "test_raise rule", fn ->
        Testing.run_rule(run.id, "test_raise")
      end

      assert get_rule(run, "test_raise").status == :running
      assert get_run(run).status == :running
    end

    test "is a noop for a finished rule, unknown ids and a malformed id", ctx do
      run = start(ctx, [@rule])
      assert {:ok, :done} = Testing.run_rule(run.id, @rule)

      assert {:ok, :noop} = Testing.run_rule(run.id, @rule)
      assert length(results(run)) == 2
      assert actions(run) == ["test_run.started", "test_run.completed"]

      assert {:ok, :noop} = Testing.run_rule(Ecto.UUID.generate(), @rule)
      assert {:ok, :noop} = Testing.run_rule("nope", @rule)
      assert {:error, :unknown_rule} = Testing.run_rule(run.id, "nope")
    end

    test "is a noop when the run is no longer running", ctx do
      run = start(ctx, [@rule, "test_skip"])

      {1, _} =
        Repo.update_all(from(r in TestRun, where: r.id == ^run.id), set: [status: :completed])

      assert {:ok, :noop} = Testing.run_rule(run.id, @rule)
      assert get_rule(run, @rule).status == :queued
      assert results(run) == []
    end

    test "completes with errors when another rule failed", ctx do
      run = start(ctx, [@rule, "test_error"])
      assert :ok = Testing.fail_rule(run.id, "test_error", :boom)
      assert get_run(run).status == :running

      assert {:ok, :done} = Testing.run_rule(run.id, @rule)
      assert %{status: :completed_with_errors, finding_count: 2} = get_run(run)
      assert List.last(audit_events(run)).payload["status"] == "completed_with_errors"
    end

    test "finalizes exactly once when rules finish one after another", ctx do
      run = start(ctx, [@rule, "test_skip"])
      subscribe_run(run)

      assert {:ok, :skipped} = Testing.run_rule(run.id, "test_skip")
      assert get_run(run).status == :running
      refute_received {:run_completed, _}

      assert {:ok, :done} = Testing.run_rule(run.id, @rule)
      assert %{status: :completed, finding_count: 2} = get_run(run)
      assert length(findings(run)) == 2

      assert_received {:run_completed, %{status: :completed, finding_count: 2}}
      refute_received {:run_completed, _}
      assert Enum.count(actions(run), &(&1 == "test_run.completed")) == 1
    end
  end

  describe "fail_rule/3" do
    test "marks the rule failed with the reason cut to 500 characters", ctx do
      run = start(ctx, [@rule, "test_error"])
      reason = String.duplicate("x", 600)

      log = capture_log(fn -> assert :ok = Testing.fail_rule(run.id, "test_error", reason) end)
      assert log =~ "failed"

      rule = get_rule(run, "test_error")
      assert rule.status == :failed
      assert rule.hit_count == 0
      assert rule.finished_at
      assert String.length(rule.error) == 500
      assert String.starts_with?(rule.error, "\"xxx")

      assert get_run(run).status == :running

      assert [_started, failed] = audit_events(run)
      assert failed.action == "test_run_rule.failed"
      assert failed.actor_id == "testing.rule_worker"
      assert failed.subject_id == run.id
      assert failed.payload == %{"rule_id" => "test_error"}
    end

    test "records the failure only once", ctx do
      run = start(ctx, [@rule, "test_error"])

      assert :ok = Testing.fail_rule(run.id, "test_error", :boom)
      assert :ok = Testing.fail_rule(run.id, "test_error", :again)

      assert get_rule(run, "test_error").error == ":boom"
      assert actions(run) == ["test_run.started", "test_run_rule.failed"]
    end

    test "finalizes the run when it was the last rule", ctx do
      run = start(ctx, ["test_error"])
      subscribe_run(run)

      assert :ok = Testing.fail_rule(run.id, "test_error", :boom)

      assert %{status: :completed_with_errors, finding_count: 0} = get_run(run)
      assert_received {:run_completed, %{status: :completed_with_errors, finding_count: 0}}

      assert actions(run) == [
               "test_run.started",
               "test_run_rule.failed",
               "test_run.completed"
             ]
    end

    test "returns :ok for ids that match nothing" do
      assert :ok = Testing.fail_rule("nope", @rule, :boom)
      assert :ok = Testing.fail_rule(Ecto.UUID.generate(), @rule, :boom)
    end
  end

  describe "broadcasts" do
    test "sends rule progress and run completion in the contract shape", ctx do
      run = start(ctx, [@rule, "test_skip"])
      run_id = run.id
      subscribe_run(run)
      subscribe_engagement(ctx)

      assert {:ok, :done} = Testing.run_rule(run.id, @rule)

      assert_received {:rule_progress, started}

      assert started == %{
               test_run_id: run_id,
               rule_id: @rule,
               status: :running,
               hit_count: 0,
               done: 0,
               total: 2
             }

      assert_received {:rule_progress, finished}

      assert finished == %{
               test_run_id: run_id,
               rule_id: @rule,
               status: :succeeded,
               hit_count: 2,
               done: 1,
               total: 2
             }

      assert_received {:test_run_updated, %{test_run_id: ^run_id, status: :running}}
      assert_received {:test_run_updated, %{test_run_id: ^run_id, status: :running}}
      refute_received {:test_run_updated, _}
      refute_received {:run_completed, _}

      assert {:ok, :skipped} = Testing.run_rule(run.id, "test_skip")

      assert_received {:rule_progress, %{rule_id: "test_skip", status: :running, done: 1}}

      assert_received {:rule_progress,
                       %{rule_id: "test_skip", status: :skipped, hit_count: 0, done: 2, total: 2}}

      assert_received {:test_run_updated, %{status: :running, finding_count: 0}}
      assert_received {:test_run_updated, updated}
      assert updated == %{test_run_id: run_id, status: :completed, finding_count: 2}
      assert_received {:run_completed, completed}
      assert completed == %{test_run_id: run_id, status: :completed, finding_count: 2}

      refute_received {:rule_progress, _}
      refute_received {:test_run_updated, _}
      refute_received {:run_completed, _}
    end
  end

  defp insert_succeeded_import(engagement, user) do
    ledger_import = insert_ledger_import(engagement, user)

    {1, _} =
      Repo.update_all(from(i in LedgerImport, where: i.id == ^ledger_import.id),
        set: [status: :succeeded]
      )

    Repo.get!(LedgerImport, ledger_import.id)
  end

  defp start(ctx, rule_ids) do
    {:ok, run} = Testing.start_test_run(ctx.scope, ctx.ledger_import, rule_ids)
    run
  end

  defp insert_queued_rule(run, rule_id) do
    {:ok, module} = Rules.fetch(rule_id)

    %TestRunRule{test_run_id: run.id}
    |> TestRunRule.create_changeset(%{rule_id: rule_id, params: module.default_params()})
    |> Repo.insert!()
  end

  defp insert_done_rule(run, rule_id, hits) do
    Repo.insert!(%TestRunRule{
      test_run_id: run.id,
      rule_id: rule_id,
      status: :succeeded,
      hit_count: length(hits)
    })

    for {entry, score} <- hits do
      Repo.insert!(%RuleResult{
        test_run_id: run.id,
        rule_id: rule_id,
        journal_entry_id: entry.id,
        score: score,
        reason: "테스트 적중",
        details: %{}
      })
    end
  end

  defp get_run(run), do: Repo.get!(TestRun, run.id)

  defp get_rule(run, rule_id),
    do: Repo.get_by!(TestRunRule, test_run_id: run.id, rule_id: rule_id)

  defp results(run), do: Repo.all(from r in RuleResult, where: r.test_run_id == ^run.id)

  defp findings(run) do
    Repo.all(from f in Finding, where: f.test_run_id == ^run.id, order_by: [desc: f.score])
  end

  defp audit_events(run) do
    Repo.all(from e in AuditEvent, where: e.subject_id == ^run.id, order_by: e.seq)
  end

  defp actions(run), do: Enum.map(audit_events(run), & &1.action)

  defp ids(rows, key), do: rows |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sort()

  defp subscribe_run(run),
    do: :ok = Phoenix.PubSub.subscribe(Tickmark.PubSub, Testing.run_topic(run.id))

  defp subscribe_engagement(ctx),
    do: :ok = Phoenix.PubSub.subscribe(Tickmark.PubSub, Engagements.topic(ctx.engagement.id))
end

defmodule Tickmark.Testing.RunnerConcurrencyTest do
  # Runs outside the sandbox: two connections have to see each other's
  # commits and block on each other's row lock, which a sandboxed
  # transaction cannot show. Every row it writes is deleted in on_exit, so
  # the run must never finalize here (an audit event cannot be deleted).
  use ExUnit.Case, async: false

  import Ecto.Query
  import Tickmark.AccountsFixtures
  import Tickmark.SchemaFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Tickmark.Accounts.User
  alias Tickmark.AuditTrail.AuditEvent
  alias Tickmark.Engagements.Engagement
  alias Tickmark.Ledger.{JournalEntry, LedgerImport}
  alias Tickmark.Repo
  alias Tickmark.Testing
  alias Tickmark.Testing.{Finding, RuleResult, Rules, TestRun, TestRunRule}

  @rule "approval_control_gap"

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    preparer = user_fixture()
    engagement = insert_engagement(preparer)
    insert_member(engagement, preparer, :preparer)
    ledger_import = insert_ledger_import(engagement, preparer)

    {1, _} =
      Repo.update_all(from(i in LedgerImport, where: i.id == ^ledger_import.id),
        set: [status: :succeeded]
      )

    insert_journal_entry(ledger_import, %{entry_number: "JE-001"})
    insert_journal_entry(ledger_import, %{entry_number: "JE-002"})
    run = insert_test_run(ledger_import, preparer, %{rule_count: 3})

    for rule_id <- [@rule, "test_skip", "test_error"] do
      {:ok, module} = Rules.fetch(rule_id)

      %TestRunRule{test_run_id: run.id}
      |> TestRunRule.create_changeset(%{rule_id: rule_id, params: module.default_params()})
      |> Repo.insert!()
    end

    on_exit(fn -> cleanup(preparer.id, engagement.id, ledger_import.id, run.id) end)

    %{run: run, engagement: engagement}
  end

  test "rules that finish at the same time serialize on the run row", ctx do
    run_id = ctx.run.id
    :ok = Phoenix.PubSub.subscribe(Tickmark.PubSub, Testing.run_topic(run_id))

    {:ok, tasks} =
      Repo.transaction(fn ->
        Repo.one!(from r in TestRun, where: r.id == ^run_id, lock: "FOR UPDATE")

        tasks =
          for rule_id <- [@rule, "test_skip"] do
            Task.async(fn ->
              :ok = Sandbox.checkout(Repo, sandbox: false)
              Testing.run_rule(run_id, rule_id)
            end)
          end

        # Both rules claim their own row and start.
        assert_receive {:rule_progress, %{status: :running}}, 5_000
        assert_receive {:rule_progress, %{status: :running}}, 5_000

        running =
          Repo.all(
            from x in TestRunRule,
              where: x.test_run_id == ^run_id and x.status == :running,
              select: x.rule_id
          )

        assert Enum.sort(running) == [@rule, "test_skip"]

        # Neither can finish while this transaction holds the run row.
        refute_receive {:rule_progress, %{status: :succeeded}}, 500
        refute_receive {:rule_progress, %{status: :skipped}}, 100
        tasks
      end)

    assert [{:ok, :done}, {:ok, :skipped}] = Task.await_many(tasks, 5_000)

    assert_receive {:rule_progress, %{rule_id: @rule, status: :succeeded, done: done_a}}, 5_000

    assert_receive {:rule_progress, %{rule_id: "test_skip", status: :skipped, done: done_b}},
                   5_000

    assert Enum.sort([done_a, done_b]) == [1, 2]
    refute_received {:run_completed, _}

    assert Repo.get!(TestRun, run_id).status == :running
    assert Repo.get_by!(TestRunRule, test_run_id: run_id, rule_id: "test_error").status == :queued
    assert Repo.aggregate(from(r in RuleResult, where: r.test_run_id == ^run_id), :count) == 2

    engagement_id = ctx.engagement.id

    assert Repo.aggregate(from(e in AuditEvent, where: e.engagement_id == ^engagement_id), :count) ==
             0
  end

  defp cleanup(user_id, engagement_id, import_id, run_id) do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    Repo.delete_all(from f in Finding, where: f.test_run_id == ^run_id)
    Repo.delete_all(from r in RuleResult, where: r.test_run_id == ^run_id)
    Repo.delete_all(from x in TestRunRule, where: x.test_run_id == ^run_id)
    Repo.delete_all(from r in TestRun, where: r.id == ^run_id)
    Repo.delete_all(from e in JournalEntry, where: e.ledger_import_id == ^import_id)
    Repo.delete_all(from i in LedgerImport, where: i.id == ^import_id)
    Repo.delete_all(from e in Engagement, where: e.id == ^engagement_id)
    Repo.delete_all(from u in User, where: u.id == ^user_id)
    Sandbox.checkin(Repo)
  end
end
