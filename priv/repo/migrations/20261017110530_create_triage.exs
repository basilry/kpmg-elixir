defmodule Tickmark.Repo.Migrations.CreateTriage do
  use Ecto.Migration

  def change do
    create table(:ai_triages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :finding_id, references(:findings, type: :binary_id, on_delete: :restrict), null: false

      add :model, :string, null: false
      add :response_model, :string, null: false
      add :prompt_version, :string, null: false
      add :input_hash, :string, null: false
      add :input, :map, null: false
      add :risk_level, :string, null: false
      add :rationale, :text, null: false
      add :suggested_procedures, :map, null: false
      add :missing_information, {:array, :text}, null: false
      add :stop_reason, :string, null: false
      add :input_tokens, :integer, null: false
      add :output_tokens, :integer, null: false
      add :latency_ms, :integer, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # Same finding, prompt, model and input means the same triage. Retries insert
    # with on_conflict: :nothing. finding_id leads this index, so lookups by finding
    # use it and no separate finding_id index is needed.
    create unique_index(:ai_triages, [:finding_id, :prompt_version, :model, :input_hash])

    create constraint(:ai_triages, :input_hash_length, check: "length(input_hash) = 64")

    create constraint(:ai_triages, :risk_level_valid,
             check: "risk_level IN ('low', 'medium', 'high')"
           )
  end
end
