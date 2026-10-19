defmodule Tickmark.Ledger.JournalEntry do
  @moduledoc """
  Journal entry header. Immutable, written only by the importer with insert_all,
  so there is no changeset.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "journal_entries" do
    field :entry_number, :string
    field :posting_date, :date
    field :document_date, :date
    # KST wall clock time from the GL, no time zone conversion
    field :entered_at, :naive_datetime
    field :fiscal_year, :integer
    field :fiscal_period, :integer
    field :entered_by, :string
    field :approved_by, :string
    field :counterparty, :string
    field :source, Ecto.Enum, values: [:manual, :system]
    field :line_count, :integer
    field :total_debit, :decimal
    field :total_credit, :decimal

    belongs_to :engagement, Tickmark.Engagements.Engagement
    belongs_to :ledger_import, Tickmark.Ledger.LedgerImport
    has_many :lines, Tickmark.Ledger.JournalLine

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
