defmodule Tickmark.Testing.TestRunRule do
  @moduledoc """
  Progress of one rule inside a test run. params is the snapshot used for this run,
  stored as jsonb so its keys come back as strings.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "test_run_rules" do
    field :rule_id, :string
    field :params, :map, default: %{}

    field :status, Ecto.Enum,
      values: [:queued, :running, :succeeded, :skipped, :failed],
      default: :queued

    field :hit_count, :integer, default: 0
    # Internal reason. The UI shows a generic message instead.
    field :error, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    belongs_to :test_run, Tickmark.Testing.TestRun

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(test_run_rule, attrs) do
    test_run_rule
    |> cast(attrs, [:rule_id, :params])
    |> validate_required([:rule_id])
    |> unique_constraint([:test_run_id, :rule_id])
    |> check_constraint(:status, name: :status_valid)
  end
end
