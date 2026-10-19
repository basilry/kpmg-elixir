defmodule Tickmark.Testing.RuleResult do
  @moduledoc """
  One rule hit on one journal entry. Immutable, written with insert_all.
  score is the rule's weight.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "rule_results" do
    field :rule_id, :string
    field :score, :integer
    field :reason, :string
    field :details, :map, default: %{}

    belongs_to :test_run, Tickmark.Testing.TestRun
    belongs_to :journal_entry, Tickmark.Ledger.JournalEntry

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
