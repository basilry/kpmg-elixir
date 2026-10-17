defmodule Tickmark.Engagements.Member do
  @moduledoc """
  A user's role on one engagement. One role per person per engagement.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "engagement_members" do
    field :role, Ecto.Enum, values: [:preparer, :reviewer]

    belongs_to :engagement, Tickmark.Engagements.Engagement
    belongs_to :user, Tickmark.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  engagement_id and user_id are set by the context, only role comes from params.
  """
  def changeset(member, attrs) do
    member
    |> cast(attrs, [:role])
    |> validate_required([:role])
    |> unique_constraint([:engagement_id, :user_id], error_key: :user_id)
    |> check_constraint(:role, name: :role_valid)
  end
end
