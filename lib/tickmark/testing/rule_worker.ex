defmodule Tickmark.Testing.RuleWorker do
  @moduledoc """
  Runs one rule of one test run (design doc 5.2, 5.4). One job per (run, rule).

  A rule that returns `{:error, reason}` is retried up to `max_attempts` with
  Oban's default backoff. On the last attempt the worker records the failure
  through `Testing.fail_rule/3` first and then cancels, so the run can still
  finish. A rule that raises or times out is retried by Oban too; its last
  attempt is recorded by `Tickmark.Jobs.FailureHandler` instead.
  """
  use Oban.Worker, queue: :rules, max_attempts: 3

  alias Tickmark.Testing

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"test_run_id" => run_id, "rule_id" => rule_id}} = job) do
    case Testing.run_rule(run_id, rule_id) do
      {:ok, _outcome} -> :ok
      {:error, reason} -> retry_or_give_up(job, run_id, rule_id, reason)
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  defp retry_or_give_up(%Oban.Job{attempt: attempt, max_attempts: max}, run_id, rule_id, reason)
       when attempt >= max do
    :ok = Testing.fail_rule(run_id, rule_id, reason)
    {:cancel, reason}
  end

  defp retry_or_give_up(_job, _run_id, _rule_id, reason), do: {:error, reason}
end
