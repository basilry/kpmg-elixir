defmodule Tickmark.Repo.Migrations.CreateEngagements do
  use Ecto.Migration

  def change do
    create table(:engagements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :client_name, :string, null: false
      add :fiscal_year, :integer, null: false
      add :period_end_date, :date, null: false
      add :performance_materiality, :decimal, precision: 18, scale: 2, null: false

      add :created_by_id, references(:users, type: :binary_id, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:engagements, [:created_by_id])

    create constraint(:engagements, :fiscal_year_range,
             check: "fiscal_year BETWEEN 2000 AND 2100"
           )

    create constraint(:engagements, :performance_materiality_positive,
             check: "performance_materiality > 0"
           )

    create table(:engagement_members, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :engagement_id, references(:engagements, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
      add :role, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # One role per person per engagement: the same user cannot be preparer and reviewer.
    create unique_index(:engagement_members, [:engagement_id, :user_id])
    create index(:engagement_members, [:user_id])

    create constraint(:engagement_members, :role_valid, check: "role IN ('preparer', 'reviewer')")
  end
end
