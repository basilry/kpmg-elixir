defmodule Tickmark.Ledger.LedgerImport do
  @moduledoc """
  One uploaded or generated GL file and the outcome of loading it.

  Created pending by `create_changeset/2`. Only `Tickmark.Ledger` moves the
  status, through the transition changesets below.
  """
  use Ecto.Schema
  import Ecto.Changeset

  # Allowed status moves. processing -> processing lets a retried job start
  # over after a crash. succeeded and failed are final.
  @transitions %{
    pending: [:processing, :failed],
    processing: [:processing, :succeeded, :failed],
    succeeded: [],
    failed: []
  }

  @summary_fields [
    :entry_count,
    :line_count,
    :total_debit,
    :total_credit,
    :warnings,
    :warning_count
  ]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "ledger_imports" do
    field :source_kind, Ecto.Enum, values: [:upload, :generated]
    field :original_filename, :string
    field :stored_filename, :string
    field :byte_size, :integer
    field :sha256, :string

    field :status, Ecto.Enum,
      values: [:pending, :processing, :succeeded, :failed],
      default: :pending

    field :entry_count, :integer, default: 0
    field :line_count, :integer, default: 0
    field :total_debit, :decimal, default: Decimal.new("0")
    field :total_credit, :decimal, default: Decimal.new("0")
    field :error_count, :integer, default: 0
    field :errors, {:array, :map}, default: []
    field :warning_count, :integer, default: 0
    field :warnings, {:array, :map}, default: []
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    belongs_to :engagement, Tickmark.Engagements.Engagement
    belongs_to :uploaded_by, Tickmark.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for the pending row. engagement_id and uploaded_by_id are set by the context.
  """
  def create_changeset(ledger_import, attrs) do
    ledger_import
    |> cast(attrs, [:source_kind, :original_filename, :stored_filename, :byte_size, :sha256])
    |> validate_required([
      :source_kind,
      :original_filename,
      :stored_filename,
      :byte_size,
      :sha256
    ])
    |> validate_length(:original_filename, max: 255)
    |> validate_number(:byte_size, greater_than: 0)
    |> validate_format(:sha256, ~r/\A[0-9a-f]{64}\z/)
    |> check_constraint(:source_kind, name: :source_kind_valid)
    |> check_constraint(:status, name: :status_valid)
  end

  @doc "True once the load has an outcome (succeeded or failed)."
  def finished?(%__MODULE__{status: status}), do: status in [:succeeded, :failed]

  @doc "pending or processing -> processing, when a worker (re)starts the load."
  def processing_changeset(%__MODULE__{} = ledger_import, started_at) do
    ledger_import
    |> change(status: :processing, started_at: started_at)
    |> validate_transition(:processing)
  end

  @doc "processing -> succeeded, with the totals and warnings of the parse summary."
  def succeeded_changeset(%__MODULE__{} = ledger_import, summary, finished_at) do
    ledger_import
    |> change(Map.take(summary, @summary_fields))
    |> change(status: :succeeded, finished_at: finished_at)
    |> validate_transition(:succeeded)
  end

  @doc """
  pending or processing -> failed. `errors` holds at most 100 items and
  `error_count` counts all of them. No errors with a count of 0 means the
  load failed for a system reason, not because of the file.
  """
  def failed_changeset(
        %__MODULE__{} = ledger_import,
        %{errors: errors, error_count: count},
        finished_at
      ) do
    ledger_import
    |> change(status: :failed, errors: errors, error_count: count, finished_at: finished_at)
    |> validate_transition(:failed)
  end

  defp validate_transition(changeset, to) do
    from = changeset.data.status

    if to in Map.fetch!(@transitions, from) do
      check_constraint(changeset, :status, name: :status_valid)
    else
      add_error(changeset, :status, "cannot move from %{from} to %{to}", from: from, to: to)
    end
  end
end
