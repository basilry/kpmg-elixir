defmodule Tickmark.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  def change do
    create table(:audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # Ordering key. UUIDs and timestamps cannot order events inside one transaction.
      add :seq, :bigint, null: false, generated: "ALWAYS AS IDENTITY"
      add :engagement_id, references(:engagements, type: :binary_id, on_delete: :restrict)
      add :actor_type, :string, null: false
      add :actor_id, :string, null: false
      add :action, :string, null: false
      add :subject_type, :string, null: false
      # Polymorphic subject, so no foreign key.
      add :subject_id, :binary_id, null: false
      add :payload, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:audit_events, [:engagement_id, :seq])
    create index(:audit_events, [:subject_type, :subject_id])

    create constraint(:audit_events, :actor_type_valid,
             check: "actor_type IN ('user', 'agent', 'system')"
           )
  end
end
