defmodule Tickmark.Testing.Finding do
  @moduledoc """
  The unit of review work: one journal entry flagged in one test run.

  Owned by Testing, which creates rows with insert_all. Two fields change later
  and each has exactly one writer:

    * `status` - only Review, through `status_changeset/2`
    * `triage_status` - only Triage, through `triage_status_changeset/2`
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:open, :concluded, :approved, :rejected]
  @triage_statuses [:none, :queued, :succeeded, :failed]

  # Allowed moves, see the data model doc 3.9. approved is final.
  @status_transitions %{
    open: [:concluded],
    concluded: [:concluded, :approved, :rejected],
    rejected: [:concluded],
    approved: []
  }

  @triage_transitions %{
    none: [:queued],
    queued: [:succeeded, :failed],
    succeeded: [:queued],
    failed: [:queued]
  }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "findings" do
    field :hit_count, :integer
    field :score, :integer
    field :rule_ids, {:array, :string}
    field :status, Ecto.Enum, values: @statuses, default: :open
    field :triage_status, Ecto.Enum, values: @triage_statuses, default: :none

    belongs_to :engagement, Tickmark.Engagements.Engagement
    belongs_to :test_run, Tickmark.Testing.TestRun
    belongs_to :journal_entry, Tickmark.Ledger.JournalEntry
    has_many :ai_triages, Tickmark.Triage.AiTriage
    has_many :conclusions, Tickmark.Review.Conclusion
    has_many :review_decisions, Tickmark.Review.ReviewDecision

    timestamps(type: :utc_datetime_usec)
  end

  def status_changeset(%__MODULE__{} = finding, to) when to in @statuses do
    finding
    |> change(status: to)
    |> validate_transition(:status, finding.status, to, @status_transitions)
    |> check_constraint(:status, name: :status_valid)
  end

  def triage_status_changeset(%__MODULE__{} = finding, to) when to in @triage_statuses do
    finding
    |> change(triage_status: to)
    |> validate_transition(:triage_status, finding.triage_status, to, @triage_transitions)
    |> check_constraint(:triage_status, name: :triage_status_valid)
  end

  defp validate_transition(changeset, field, from, to, transitions) do
    if to in Map.fetch!(transitions, from) do
      changeset
    else
      add_error(changeset, field, "cannot move from %{from} to %{to}", from: from, to: to)
    end
  end
end
