defmodule Tickmark.Repo.Migrations.CreateTesting do
  use Ecto.Migration

  def change do
    create table(:test_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :engagement_id, references(:engagements, type: :binary_id, on_delete: :restrict),
        null: false

      add :ledger_import_id,
          references(:ledger_imports, type: :binary_id, on_delete: :restrict),
          null: false

      add :started_by_id, references(:users, type: :binary_id, on_delete: :restrict), null: false

      add :status, :string, null: false, default: "running"
      add :rule_count, :integer, null: false
      # Snapshot at start time, so changing the default later does not move old queues.
      add :triage_threshold, :integer, null: false, default: 25
      add :finding_count, :integer, null: false, default: 0
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # At most one running test per import. A double click hits this index instead of
    # starting two runs.
    create unique_index(:test_runs, [:ledger_import_id],
             where: "status = 'running'",
             name: :test_runs_one_running_per_import
           )

    create index(:test_runs, [:engagement_id, :inserted_at])

    create constraint(:test_runs, :status_valid,
             check: "status IN ('running', 'completed', 'completed_with_errors')"
           )

    create table(:test_run_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :test_run_id, references(:test_runs, type: :binary_id, on_delete: :restrict),
        null: false

      add :rule_id, :string, null: false
      add :params, :map, null: false, default: %{}
      add :status, :string, null: false, default: "queued"
      add :hit_count, :integer, null: false, default: 0
      add :error, :text
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:test_run_rules, [:test_run_id, :rule_id])

    create constraint(:test_run_rules, :status_valid,
             check: "status IN ('queued', 'running', 'succeeded', 'skipped', 'failed')"
           )

    create table(:rule_results, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :test_run_id, references(:test_runs, type: :binary_id, on_delete: :restrict),
        null: false

      add :rule_id, :string, null: false

      add :journal_entry_id,
          references(:journal_entries, type: :binary_id, on_delete: :restrict),
          null: false

      add :score, :integer, null: false
      add :reason, :text, null: false
      add :details, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:rule_results, [:test_run_id, :rule_id, :journal_entry_id])
    create index(:rule_results, [:test_run_id, :journal_entry_id])
    create constraint(:rule_results, :score_range, check: "score BETWEEN 1 AND 100")

    create table(:findings, primary_key: false) do
      # Findings are built with INSERT ... SELECT, where Ecto does not generate ids.
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :engagement_id, references(:engagements, type: :binary_id, on_delete: :restrict),
        null: false

      add :test_run_id, references(:test_runs, type: :binary_id, on_delete: :restrict),
        null: false

      add :journal_entry_id,
          references(:journal_entries, type: :binary_id, on_delete: :restrict),
          null: false

      add :hit_count, :integer, null: false
      add :score, :integer, null: false
      add :rule_ids, {:array, :text}, null: false
      add :status, :string, null: false, default: "open"
      add :triage_status, :string, null: false, default: "none"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:findings, [:test_run_id, :journal_entry_id])
    create index(:findings, [:test_run_id, :status])
    create index(:findings, [:test_run_id, :score])
    create constraint(:findings, :score_range, check: "score BETWEEN 0 AND 100")

    create constraint(:findings, :status_valid,
             check: "status IN ('open', 'concluded', 'approved', 'rejected')"
           )

    create constraint(:findings, :triage_status_valid,
             check: "triage_status IN ('none', 'queued', 'succeeded', 'failed')"
           )
  end
end
