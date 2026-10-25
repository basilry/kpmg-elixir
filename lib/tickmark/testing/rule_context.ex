defmodule Tickmark.Testing.RuleContext do
  @moduledoc """
  What a rule gets to run with. `params` is the snapshot stored in
  `test_run_rules.params`, so its keys are strings.
  """

  @enforce_keys [:test_run_id, :ledger_import_id, :engagement, :params]
  defstruct [:test_run_id, :ledger_import_id, :engagement, :params]

  @type t :: %__MODULE__{
          test_run_id: Ecto.UUID.t(),
          ledger_import_id: Ecto.UUID.t(),
          engagement: Tickmark.Engagements.Engagement.t(),
          params: map()
        }
end
