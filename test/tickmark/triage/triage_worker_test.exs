defmodule Tickmark.Triage.TriageWorkerTest do
  use Tickmark.DataCase, async: true
  use Oban.Testing, repo: Tickmark.Repo

  import Tickmark.AccountsFixtures
  import Tickmark.SchemaFixtures

  alias Tickmark.AuditTrail.AuditEvent
  alias Tickmark.Testing.Finding
  alias Tickmark.Triage.{AiTriage, TriageWorker}

  @moduletag :capture_log

  setup do
    preparer = user_fixture()
    engagement = insert_engagement(preparer)
    insert_member(engagement, preparer, :preparer)
    ledger_import = insert_ledger_import(engagement, preparer)
    run = insert_test_run(ledger_import, preparer)
    entry = insert_journal_entry(ledger_import)
    finding = insert_finding(run, entry, %{triage_status: :queued})

    %{finding: finding, args: %{"finding_id" => finding.id}}
  end

  test "runs on the llm queue with 5 attempts, a 3 minute timeout and doubling backoff", ctx do
    job = Ecto.Changeset.apply_changes(TriageWorker.new(ctx.args))

    assert job.queue == "llm"
    assert job.max_attempts == 5
    assert TriageWorker.timeout(job) == :timer.minutes(3)
    assert Enum.map(1..4, &TriageWorker.backoff(%{job | attempt: &1})) == [20, 40, 80, 160]
  end

  describe "perform/1" do
    test "stores the suggestion of a queued finding", ctx do
      assert :ok = perform_job(TriageWorker, ctx.args)

      assert Repo.get!(Finding, ctx.finding.id).triage_status == :succeeded
      assert [%AiTriage{model: "fake-triage-v1"}] = Repo.all(AiTriage)
    end

    test "finishes without changes when the finding is not queued", ctx do
      {1, _} =
        Repo.update_all(from(f in Finding, where: f.id == ^ctx.finding.id),
          set: [triage_status: :succeeded]
        )

      assert :ok = perform_job(TriageWorker, ctx.args)
      assert Repo.all(AiTriage) == []
    end
  end

  describe "handle_result/2" do
    test "a result finishes the job", ctx do
      assert :ok = TriageWorker.handle_result({:ok, %AiTriage{}}, job(ctx))
      assert :ok = TriageWorker.handle_result({:ok, :noop}, job(ctx))
      assert queued?(ctx)
    end

    test "a rate limit snoozes for the server's seconds, 30 by default", ctx do
      assert {:snooze, 45} = TriageWorker.handle_result({:error, {:rate_limited, 45}}, job(ctx))
      assert {:snooze, 30} = TriageWorker.handle_result({:error, {:rate_limited, nil}}, job(ctx))

      assert {:snooze, 45} =
               TriageWorker.handle_result(
                 {:error, {:rate_limited, 45}},
                 job(ctx, meta: %{snoozed: 9})
               )

      assert queued?(ctx)
    end

    test "after ten snoozes a rate limit retries, then gives up on the last attempt", ctx do
      assert {:error, :rate_limited} =
               TriageWorker.handle_result(
                 {:error, {:rate_limited, 45}},
                 job(ctx, meta: %{snoozed: 10})
               )

      assert queued?(ctx)

      assert {:cancel, :rate_limited} =
               TriageWorker.handle_result(
                 {:error, {:rate_limited, 45}},
                 job(ctx, attempt: 5, meta: %{snoozed: 10})
               )

      assert failure_reason(ctx) == "rate_limited"
    end

    test "a retryable error retries until the last attempt", ctx do
      assert {:error, :transport_error} =
               TriageWorker.handle_result(
                 {:error, {:retryable, :transport_error}},
                 job(ctx, attempt: 4)
               )

      assert queued?(ctx)

      assert {:cancel, :transport_error} =
               TriageWorker.handle_result(
                 {:error, {:retryable, :transport_error}},
                 job(ctx, attempt: 5)
               )

      assert failure_reason(ctx) == "transient"
    end

    test "a fatal error gives up at once", ctx do
      assert {:cancel, :refusal} =
               TriageWorker.handle_result({:error, {:fatal, :refusal}}, job(ctx, attempt: 1))

      assert failure_reason(ctx) == "refusal"
    end
  end

  test "a snooze does not consume an attempt (Oban 2.24 Basic engine)", ctx do
    {:ok, job} = Oban.insert(TriageWorker.new(ctx.args))
    now = DateTime.utc_now()

    # What the producer does when it hands the job to a worker.
    {1, _} =
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
        set: [state: "executing", attempt: 1, attempted_at: now]
      )

    executing = Repo.get!(Oban.Job, job.id)
    assert :ok = Oban.Engine.snooze_job(Oban.config(), executing, 30)

    snoozed = Repo.get!(Oban.Job, job.id)
    assert snoozed.state == "scheduled"
    assert snoozed.attempt == 0
    assert snoozed.meta == %{"snoozed" => 1}
    assert DateTime.diff(snoozed.scheduled_at, now) in 29..31
  end

  defp job(ctx, opts \\ []) do
    build_job(TriageWorker, ctx.args, Keyword.merge([attempt: 1, max_attempts: 5], opts))
  end

  defp queued?(ctx), do: Repo.get!(Finding, ctx.finding.id).triage_status == :queued

  defp failure_reason(ctx) do
    assert Repo.get!(Finding, ctx.finding.id).triage_status == :failed

    Repo.get_by!(AuditEvent, action: "ai_triage.failed", subject_id: ctx.finding.id).payload[
      "reason"
    ]
  end
end
