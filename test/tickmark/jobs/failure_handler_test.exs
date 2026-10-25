defmodule Tickmark.Jobs.FailureHandlerTest do
  use Tickmark.DataCase, async: true
  use Oban.Testing, repo: Tickmark.Repo

  import ExUnit.CaptureLog
  import Tickmark.AccountsFixtures
  import Tickmark.SchemaFixtures

  alias Tickmark.Accounts.Scope
  alias Tickmark.AuditTrail.AuditEvent
  alias Tickmark.Jobs.FailureHandler
  alias Tickmark.Ledger.LedgerImport
  alias Tickmark.Testing
  alias Tickmark.Testing.{Finding, RuleWorker, TestRun, TestRunRule}

  @moduletag :capture_log
  @event [:oban, :job, :exception]
  @handler_id "tickmark-jobs-failure-handler"

  setup do
    preparer = user_fixture()
    engagement = insert_engagement(preparer)
    insert_member(engagement, preparer, :preparer)
    ledger_import = insert_ledger_import(engagement, preparer)

    {1, _} =
      Repo.update_all(from(i in LedgerImport, where: i.id == ^ledger_import.id),
        set: [status: :succeeded]
      )

    %{
      preparer: preparer,
      scope: Scope.for_user(preparer),
      engagement: engagement,
      ledger_import: Repo.get!(LedgerImport, ledger_import.id)
    }
  end

  test "attach/0 can be called more than once and keeps one handler" do
    assert :ok = FailureHandler.attach()
    assert :ok = FailureHandler.attach()
    assert attached?()
  end

  test "records the failure of a rule job whose last attempt raised", ctx do
    run = start(ctx, ["test_raise"])

    assert_raise RuntimeError, "test_raise rule", fn ->
      perform_job(RuleWorker, args(run, "test_raise"), attempt: 3)
    end

    rule = get_rule(run, "test_raise")
    assert rule.status == :failed
    assert rule.error =~ "test_raise rule"
    assert %{status: :completed_with_errors, finding_count: 0} = Repo.get!(TestRun, run.id)
  end

  test "leaves a rule alone while its job will still be retried", ctx do
    run = start(ctx, ["test_raise"])

    assert_raise RuntimeError, fn ->
      perform_job(RuleWorker, args(run, "test_raise"), attempt: 1)
    end

    assert get_rule(run, "test_raise").status == :running
    assert Repo.get!(TestRun, run.id).status == :running
  end

  test "marks an import failed when its job gave up", ctx do
    pending = insert_ledger_import(ctx.engagement, ctx.preparer)

    execute(%Oban.Job{
      worker: "Tickmark.Ledger.ImportWorker",
      args: %{"ledger_import_id" => pending.id},
      attempt: 3,
      max_attempts: 3
    })

    assert Repo.get!(LedgerImport, pending.id).status == :failed
  end

  test "ignores an import job that will be retried", ctx do
    pending = insert_ledger_import(ctx.engagement, ctx.preparer)

    execute(%Oban.Job{
      worker: "Tickmark.Ledger.ImportWorker",
      args: %{"ledger_import_id" => pending.id},
      attempt: 2,
      max_attempts: 3
    })

    assert Repo.get!(LedgerImport, pending.id).status == :pending
  end

  test "marks a queued finding failed when its triage job gave up", ctx do
    finding = queued_finding(ctx)

    execute(%Oban.Job{
      worker: "Tickmark.Triage.TriageWorker",
      args: %{"finding_id" => finding.id},
      attempt: 5,
      max_attempts: 5
    })

    assert Repo.get!(Finding, finding.id).triage_status == :failed

    assert %{payload: %{"reason" => "worker_crashed"}} =
             Repo.get_by!(AuditEvent, action: "ai_triage.failed", subject_id: finding.id)
  end

  test "leaves a queued finding alone while its triage job will be retried", ctx do
    finding = queued_finding(ctx)

    execute(%Oban.Job{
      worker: "Tickmark.Triage.TriageWorker",
      args: %{"finding_id" => finding.id},
      attempt: 2,
      max_attempts: 5
    })

    assert Repo.get!(Finding, finding.id).triage_status == :queued
  end

  test "ignores other workers and events without a job" do
    execute(%Oban.Job{worker: "Tickmark.Elsewhere", args: %{}, attempt: 3, max_attempts: 3})
    :telemetry.execute(@event, %{}, %{no_job: true})
    assert attached?()
  end

  test "stays attached when recording the failure raises", ctx do
    run = start(ctx, ["test_raise"])

    job = %Oban.Job{
      worker: "Tickmark.Testing.RuleWorker",
      args: args(run, "test_raise"),
      attempt: 3,
      max_attempts: 3
    }

    # A process outside the sandbox has no database connection, so
    # fail_rule raises inside the handler.
    log =
      capture_log(fn ->
        {pid, ref} = spawn_monitor(fn -> execute(job) end)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
      end)

    assert log =~ "FailureHandler could not record"
    assert attached?()
    assert get_rule(run, "test_raise").status == :queued
  end

  defp execute(job) do
    :telemetry.execute(@event, %{duration: 0}, %{
      job: job,
      kind: :error,
      reason: %RuntimeError{message: "boom"},
      state: :discard
    })
  end

  defp attached? do
    Enum.count(:telemetry.list_handlers(@event), &(&1.id == @handler_id)) == 1
  end

  defp start(ctx, rule_ids) do
    {:ok, run} = Testing.start_test_run(ctx.scope, ctx.ledger_import, rule_ids)
    run
  end

  defp args(run, rule_id), do: %{"test_run_id" => run.id, "rule_id" => rule_id}

  defp get_rule(run, rule_id),
    do: Repo.get_by!(TestRunRule, test_run_id: run.id, rule_id: rule_id)

  defp queued_finding(ctx) do
    run = insert_test_run(ctx.ledger_import, ctx.preparer)
    entry = insert_journal_entry(ctx.ledger_import)
    insert_finding(run, entry, %{triage_status: :queued})
  end
end
