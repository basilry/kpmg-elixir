defmodule Tickmark.Ledger.JournalLine do
  @moduledoc """
  Journal entry line. Immutable, written only by the importer with insert_all.
  description is untrusted text and must be wrapped as such in AI input.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "journal_lines" do
    field :line_number, :integer
    field :account_code, :string
    field :account_name, :string
    field :debit, :decimal, default: Decimal.new("0")
    field :credit, :decimal, default: Decimal.new("0")
    field :description, :string

    belongs_to :journal_entry, Tickmark.Ledger.JournalEntry
    belongs_to :ledger_import, Tickmark.Ledger.LedgerImport

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
