defmodule Tickmark.Repo.Migrations.CreateLedger do
  use Ecto.Migration

  def change do
    create table(:ledger_imports, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :engagement_id, references(:engagements, type: :binary_id, on_delete: :restrict),
        null: false

      add :uploaded_by_id, references(:users, type: :binary_id, on_delete: :restrict), null: false

      add :source_kind, :string, null: false
      add :original_filename, :string, null: false
      add :stored_filename, :string, null: false
      add :byte_size, :bigint, null: false
      add :sha256, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :entry_count, :integer, null: false, default: 0
      add :line_count, :integer, null: false, default: 0
      add :total_debit, :decimal, precision: 18, scale: 2, null: false, default: 0
      add :total_credit, :decimal, precision: 18, scale: 2, null: false, default: 0
      add :error_count, :integer, null: false, default: 0
      add :errors, {:array, :map}, null: false, default: []
      add :warning_count, :integer, null: false, default: 0
      add :warnings, {:array, :map}, null: false, default: []
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ledger_imports, [:engagement_id, :inserted_at])

    create constraint(:ledger_imports, :source_kind_valid,
             check: "source_kind IN ('upload', 'generated')"
           )

    create constraint(:ledger_imports, :status_valid,
             check: "status IN ('pending', 'processing', 'succeeded', 'failed')"
           )

    create table(:journal_entries, primary_key: false) do
      # Generated in Elixir at load time so lines can reference it without RETURNING.
      add :id, :binary_id, primary_key: true

      add :engagement_id, references(:engagements, type: :binary_id, on_delete: :restrict),
        null: false

      add :ledger_import_id,
          references(:ledger_imports, type: :binary_id, on_delete: :restrict),
          null: false

      add :entry_number, :string, null: false
      add :posting_date, :date, null: false
      add :document_date, :date, null: false
      # KST wall clock time from the GL file, stored without time zone conversion.
      add :entered_at, :naive_datetime, null: false
      add :fiscal_year, :integer, null: false
      add :fiscal_period, :integer, null: false
      add :entered_by, :string, null: false
      add :approved_by, :string
      add :counterparty, :string
      add :source, :string, null: false
      add :line_count, :integer, null: false
      add :total_debit, :decimal, precision: 18, scale: 2, null: false
      add :total_credit, :decimal, precision: 18, scale: 2, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:journal_entries, [:ledger_import_id, :entry_number])
    create index(:journal_entries, [:ledger_import_id, :posting_date])
    create index(:journal_entries, [:engagement_id])

    create constraint(:journal_entries, :fiscal_period_range,
             check: "fiscal_period BETWEEN 1 AND 13"
           )

    create constraint(:journal_entries, :source_valid, check: "source IN ('manual', 'system')")
    create constraint(:journal_entries, :balanced, check: "total_debit = total_credit")

    create table(:journal_lines, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :journal_entry_id,
          references(:journal_entries, type: :binary_id, on_delete: :restrict),
          null: false

      add :ledger_import_id,
          references(:ledger_imports, type: :binary_id, on_delete: :restrict),
          null: false

      add :line_number, :integer, null: false
      add :account_code, :string, null: false
      add :account_name, :string, null: false
      add :debit, :decimal, precision: 18, scale: 2, null: false, default: 0
      add :credit, :decimal, precision: 18, scale: 2, null: false, default: 0
      add :description, :text

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:journal_lines, [:journal_entry_id, :line_number])
    create index(:journal_lines, [:ledger_import_id, :account_code])
    create constraint(:journal_lines, :line_number_positive, check: "line_number > 0")
    create constraint(:journal_lines, :debit_non_negative, check: "debit >= 0")
    create constraint(:journal_lines, :credit_non_negative, check: "credit >= 0")

    create constraint(:journal_lines, :one_side_positive,
             check: "(debit > 0 AND credit = 0) OR (debit = 0 AND credit > 0)"
           )
  end
end
