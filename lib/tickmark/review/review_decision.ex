defmodule Tickmark.Review.ReviewDecision do
  @moduledoc """
  A reviewer's decision on one conclusion. Immutable, one per conclusion.

  preparer_id is copied from the conclusion. The composite foreign key
  (conclusion_id, preparer_id) makes the copy impossible to fake, and the
  reviewer_not_preparer CHECK blocks self-review even if the context check is skipped.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "review_decisions" do
    field :decision, Ecto.Enum, values: [:approved, :rejected]
    field :comment, :string

    belongs_to :finding, Tickmark.Testing.Finding
    belongs_to :conclusion, Tickmark.Review.Conclusion
    belongs_to :preparer, Tickmark.Accounts.User
    belongs_to :reviewer, Tickmark.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  All ids are set by the Review context. A rejection needs a comment.
  """
  def changeset(review_decision, attrs) do
    review_decision
    |> cast(attrs, [:decision, :comment])
    |> validate_required([:decision])
    |> validate_length(:comment, max: 2000)
    |> validate_comment_on_reject()
    |> unique_constraint(:conclusion_id)
    |> foreign_key_constraint(:conclusion_id, name: :review_decisions_conclusion_id_fkey)
    |> check_constraint(:reviewer_id, name: :reviewer_not_preparer)
    |> check_constraint(:comment, name: :comment_required_on_reject)
    |> check_constraint(:decision, name: :decision_valid)
  end

  defp validate_comment_on_reject(changeset) do
    if get_field(changeset, :decision) == :rejected do
      validate_required(changeset, [:comment])
    else
      changeset
    end
  end
end
