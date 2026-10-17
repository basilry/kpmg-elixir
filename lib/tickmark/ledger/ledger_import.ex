defmodule Tickmark.Ledger.LedgerImport do
  @moduledoc """
  One uploaded or generated GL file and the outcome of loading it.
  """
  use Ecto.Schema
  import Ecto.Changeset

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
end
