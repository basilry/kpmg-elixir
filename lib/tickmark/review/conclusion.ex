defmodule Tickmark.Review.Conclusion do
  @moduledoc """
  A preparer's conclusion on a finding. Immutable; resubmitting adds a new row.
  Submitting a conclusion is the request for review.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "conclusions" do
    field :outcome, Ecto.Enum, values: [:no_exception, :needs_follow_up, :exception]
    field :comment, :string

    belongs_to :finding, Tickmark.Testing.Finding
    belongs_to :preparer, Tickmark.Accounts.User
    # The AI suggestion the preparer looked at, if any
    belongs_to :ai_triage, Tickmark.Triage.AiTriage

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  finding_id and preparer_id are set by the Review context. ai_triage_id comes
  from the form, so the context must check it belongs to the same finding.
  """
  def changeset(conclusion, attrs) do
    conclusion
    |> cast(attrs, [:outcome, :comment, :ai_triage_id])
    |> validate_required([:outcome, :comment])
    |> validate_length(:comment, min: 1, max: 2000)
    |> foreign_key_constraint(:ai_triage_id)
    |> check_constraint(:outcome, name: :outcome_valid)
  end
end
