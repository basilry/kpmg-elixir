defmodule Tickmark.Testing.Runner do
  @moduledoc """
  Starting a run and the job-side steps of a run (design doc 5.3, 5.4).

  Skeleton from the main session so `Tickmark.Testing` compiles. Worker A
  replaces this module in round 3 (WBS 2.1). Until then every function
  raises.
  """

  def start_test_run(_scope, _ledger_import, _rule_ids), do: raise("Runner is not built yet")

  def run_rule(_test_run_id, _rule_id), do: raise("Runner is not built yet")

  def fail_rule(_test_run_id, _rule_id, _reason), do: raise("Runner is not built yet")
end
