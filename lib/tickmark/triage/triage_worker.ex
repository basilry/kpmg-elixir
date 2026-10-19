defmodule Tickmark.Triage.TriageWorker do
  @moduledoc """
  Runs the AI triage of one finding on the llm queue (design doc 5.5.1).

  The client classifies a failure; this worker decides what Oban does with
  it: wait out a rate limit with snooze, retry a transient error with
  backoff, or give up and record the failure on the finding. A raise or a
  timeout on the last attempt is recorded by `Tickmark.Jobs.FailureHandler`.
  """
  use Oban.Worker, queue: :llm, max_attempts: 5

  alias Tickmark.Triage

  @max_snoozes 10
  @default_snooze_seconds 30

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"finding_id" => finding_id}} = job) do
    finding_id |> Triage.triage_finding() |> handle_result(job)
  end

  # Longer than the client's 120 second receive_timeout, so a slow response
  # comes back as a client error instead of Oban killing the job.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(3)

  # 20, 40, 80 and 160 seconds between the five attempts.
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: 10 * 2 ** attempt

  @doc """
  Maps a `Triage.triage_finding/1` result to the worker's return (the table
  in design doc 5.5.1). Public so the table can be tested with jobs built by
  `Oban.Testing` without a client that fails on demand.
  """
  @spec handle_result({:ok, term()} | {:error, Tickmark.AI.Client.error()}, Oban.Job.t()) ::
          Oban.Worker.result()
  def handle_result({:ok, _result}, _job), do: :ok

  # A snooze puts the job back to scheduled without using up an attempt
  # (Oban 2.24 Basic engine: attempt - 1, meta.snoozed + 1), so meta.snoozed
  # is what caps how long a rate limit can keep the job alive.
  def handle_result({:error, {:rate_limited, seconds}}, %Oban.Job{meta: meta} = job) do
    if Map.get(meta, "snoozed", 0) < @max_snoozes do
      {:snooze, seconds || @default_snooze_seconds}
    else
      retry_or_give_up(job, :rate_limited, :rate_limited)
    end
  end

  def handle_result({:error, {:retryable, reason}}, job) do
    retry_or_give_up(job, {:retryable, reason}, reason)
  end

  def handle_result({:error, {:fatal, reason}}, job) do
    give_up(job, {:fatal, reason}, reason)
  end

  defp retry_or_give_up(%Oban.Job{attempt: attempt, max_attempts: max} = job, failure, reason)
       when attempt >= max do
    give_up(job, failure, reason)
  end

  defp retry_or_give_up(_job, _failure, reason), do: {:error, reason}

  defp give_up(%Oban.Job{args: %{"finding_id" => finding_id}}, failure, reason) do
    :ok = Triage.mark_failed(finding_id, failure)
    {:cancel, reason}
  end
end
