defmodule Tickmark.Testing.TestRun do
  @moduledoc """
  One run of a set of rules over one ledger import.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "test_runs" do
    field :status, Ecto.Enum,
      values: [:running, :completed, :completed_with_errors],
      default: :running

    field :rule_count, :integer
    # Snapshot at start time. Findings at or above it form the review queue.
    field :triage_threshold, :integer, default: 25
    field :finding_count, :integer, default: 0
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    belongs_to :engagement, Tickmark.Engagements.Engagement
    belongs_to :ledger_import, Tickmark.Ledger.LedgerImport
    belongs_to :started_by, Tickmark.Accounts.User
    has_many :test_run_rules, Tickmark.Testing.TestRunRule
    has_many :findings, Tickmark.Testing.Finding

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for the running row. Foreign keys are set by the context.
  The partial unique index turns a second running run on the same import
  into a changeset error instead of a raised exception.
  """
  def create_changeset(test_run, attrs) do
    test_run
    |> cast(attrs, [:rule_count, :triage_threshold, :started_at])
    |> validate_required([:rule_count, :triage_threshold, :started_at])
    |> validate_number(:rule_count, greater_than: 0)
    |> validate_number(:triage_threshold, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> unique_constraint(:ledger_import_id, name: :test_runs_one_running_per_import)
    |> check_constraint(:status, name: :status_valid)
  end
end
