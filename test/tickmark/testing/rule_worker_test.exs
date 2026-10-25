defmodule Tickmark.Testing.RuleWorkerTest do
  use Tickmark.DataCase, async: true
  use Oban.Testing, repo: Tickmark.Repo

  import ExUnit.CaptureLog
  import Tickmark.AccountsFixtures
  import Tickmark.SchemaFixtures

  alias Tickmark.Accounts.Scope
  alias Tickmark.Ledger.LedgerImport
  alias Tickmark.Testing
  alias Tickmark.Testing.{RuleWorker, TestRun, TestRunRule}

  @moduletag :capture_log
  @rule "approval_control_gap"

  setup do
    preparer = user_fixture()
    engagement = insert_engagement(preparer)
    insert_member(engagement, preparer, :preparer)
    ledger_import = insert_ledger_import(engagement, preparer)

    {1, _} =
      Repo.update_all(from(i in LedgerImport, where: i.id == ^ledger_import.id),
        set: [status: :succeeded]
      )

    insert_journal_entry(ledger_import)

    %{scope: Scope.for_user(preparer), ledger_import: Repo.get!(LedgerImport, ledger_import.id)}
  end

  test "runs on the rules queue with 3 attempts and a 5 minute timeout" do
    job = Ecto.Changeset.apply_changes(RuleWorker.new(%{"test_run_id" => "id", "rule_id" => "r"}))

    assert job.queue == "rules"
    assert job.max_attempts == 3
    assert RuleWorker.timeout(job) == :timer.minutes(5)
  end

  test "returns :ok when the rule succeeds, is skipped or was already finished", ctx do
    run = start(ctx, [@rule, "test_skip"])

    assert :ok = perform(run, @rule)
    assert :ok = perform(run, @rule)
    assert get_rule(run, @rule).hit_count == 1

    assert :ok = perform(run, "test_skip")
    assert %{status: :completed, finding_count: 1} = Repo.get!(TestRun, run.id)
  end

  test "retries a rule error, then records the failure on the last attempt and cancels", ctx do
    run = start(ctx, ["test_error"])

    assert {:error, :test_error} = perform(run, "test_error", attempt: 1)
    assert get_rule(run, "test_error").status == :running
    assert Repo.get!(TestRun, run.id).status == :running

    log =
      capture_log(fn ->
        assert {:cancel, :test_error} = perform(run, "test_error", attempt: 3)
      end)

    assert log =~ "test_error"
    assert %{status: :failed, error: ":test_error"} = get_rule(run, "test_error")
    assert %{status: :completed_with_errors, finding_count: 0} = Repo.get!(TestRun, run.id)
  end

  test "drains the jobs that start_test_run queued and completes the run", ctx do
    run = start(ctx, [@rule, "test_skip"])

    assert %{success: 2, failure: 0} = Oban.drain_queue(queue: :rules, with_safety: false)
    assert %{status: :completed, finding_count: 1} = Repo.get!(TestRun, run.id)
  end

  defp start(ctx, rule_ids) do
    {:ok, run} = Testing.start_test_run(ctx.scope, ctx.ledger_import, rule_ids)
    run
  end

  defp perform(run, rule_id, opts \\ []) do
    perform_job(RuleWorker, %{"test_run_id" => run.id, "rule_id" => rule_id}, opts)
  end

  defp get_rule(run, rule_id),
    do: Repo.get_by!(TestRunRule, test_run_id: run.id, rule_id: rule_id)
end
