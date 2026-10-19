defmodule Tickmark.Repo.Migrations.CreateReview do
  use Ecto.Migration

  def change do
    create table(:conclusions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :finding_id, references(:findings, type: :binary_id, on_delete: :restrict), null: false

      add :preparer_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
      add :outcome, :string, null: false
      add :comment, :text, null: false
      add :ai_triage_id, references(:ai_triages, type: :binary_id, on_delete: :restrict)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # Target of the composite foreign key below. id alone is already unique; this pair
    # lets review_decisions prove which preparer wrote the conclusion.
    create unique_index(:conclusions, [:id, :preparer_id])
    create index(:conclusions, [:finding_id, :inserted_at])

    create constraint(:conclusions, :outcome_valid,
             check: "outcome IN ('no_exception', 'needs_follow_up', 'exception')"
           )

    create table(:review_decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :finding_id, references(:findings, type: :binary_id, on_delete: :restrict), null: false

      add :preparer_id, references(:users, type: :binary_id, on_delete: :restrict), null: false

      # (conclusion_id, preparer_id) must match a real conclusion, so preparer_id
      # cannot be forged to get past the reviewer_not_preparer check.
      add :conclusion_id,
          references(:conclusions,
            type: :binary_id,
            with: [preparer_id: :preparer_id],
            on_delete: :restrict
          ),
          null: false

      add :reviewer_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
      add :decision, :string, null: false
      add :comment, :text

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:review_decisions, [:conclusion_id])
    create index(:review_decisions, [:finding_id])

    create constraint(:review_decisions, :decision_valid,
             check: "decision IN ('approved', 'rejected')"
           )

    # A NULL comment would make length(btrim(comment)) NULL and the CHECK would pass,
    # so the NULL case is spelled out.
    create constraint(:review_decisions, :comment_required_on_reject,
             check:
               "decision = 'approved' OR (comment IS NOT NULL AND length(btrim(comment)) > 0)"
           )

    create constraint(:review_decisions, :reviewer_not_preparer,
             check: "reviewer_id <> preparer_id"
           )
  end
end
