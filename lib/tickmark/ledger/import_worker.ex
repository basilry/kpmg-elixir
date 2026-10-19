defmodule Tickmark.Ledger.ImportWorker do
  @moduledoc """
  Loads one GL file on the ingest queue (architecture doc 5.1).

  The job state follows the domain outcome:

    * loaded -> `:ok` (completed)
    * the file was rejected, or the import is gone -> `{:cancel, reason}`.
      The import row already says failed, so retrying cannot help.
    * any other error -> `{:error, reason}`, retried with backoff. On the
      last attempt the import is marked failed first, then the job is
      cancelled.

  A raise or a timeout on the last attempt is handled outside the worker by
  the job failure handler, which calls `Tickmark.Ledger.mark_import_failed/2`.
  """
  use Oban.Worker, queue: :ingest, max_attempts: 3

  alias Tickmark.Ledger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"ledger_import_id" => import_id}} = job) do
    case Ledger.process_import(import_id) do
      {:ok, %{status: :succeeded}} -> :ok
      {:ok, %{status: :failed}} -> {:cancel, :import_failed}
      {:error, :not_found} -> {:cancel, :not_found}
      {:error, reason} -> retry_or_give_up(job, import_id, reason)
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  defp retry_or_give_up(%Oban.Job{attempt: attempt, max_attempts: max}, import_id, reason)
       when attempt >= max do
    :ok = Ledger.mark_import_failed(import_id, reason)
    {:cancel, reason}
  end

  defp retry_or_give_up(_job, _import_id, reason), do: {:error, reason}
end
