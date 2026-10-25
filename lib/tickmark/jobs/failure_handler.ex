defmodule Tickmark.Jobs.FailureHandler do
  @moduledoc """
  Records the final failure of a job that raised or timed out (design doc 5.4).

  Oban emits `[:oban, :job, :exception]` for every failed attempt. Only the
  last one matters here: the job will not run again, so the row it was
  working on has to be marked failed or the import or run would stay in
  progress forever. A job that returns `{:error, _}` on its last attempt
  marks the row itself before cancelling, which is why the functions called
  here are idempotent.

  The handler id is fixed, so `attach/0` is safe to call more than once.
  """
  require Logger

  alias Tickmark.{Ledger, Testing, Triage}

  @handler_id "tickmark-jobs-failure-handler"
  @event [:oban, :job, :exception]

  @spec attach() :: :ok
  def attach do
    case :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def handle_event(@event, _measurements, %{job: %Oban.Job{} = job} = meta, _config) do
    if job.attempt >= job.max_attempts do
      record_failure(job, Map.get(meta, :reason))
    end

    :ok
  catch
    # Telemetry detaches a handler that raises, and then the next final
    # failure would go unrecorded. Log it and stay attached.
    kind, reason ->
      Logger.error(
        "FailureHandler could not record the failure of job #{inspect(job.id)} " <>
          "(#{job.worker}): #{inspect({kind, reason})}"
      )

      :ok
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  defp record_failure(
         %Oban.Job{worker: "Tickmark.Ledger.ImportWorker", args: %{"ledger_import_id" => id}},
         reason
       ) do
    Ledger.mark_import_failed(id, reason)
  end

  defp record_failure(
         %Oban.Job{
           worker: "Tickmark.Testing.RuleWorker",
           args: %{"test_run_id" => run_id, "rule_id" => rule_id}
         },
         reason
       ) do
    Testing.fail_rule(run_id, rule_id, reason)
  end

  defp record_failure(
         %Oban.Job{worker: "Tickmark.Triage.TriageWorker", args: %{"finding_id" => id}},
         _reason
       ) do
    Triage.mark_failed(id, :worker_crashed)
  end

  # Other workers record their own failures.
  defp record_failure(_job, _reason), do: :ok
end
