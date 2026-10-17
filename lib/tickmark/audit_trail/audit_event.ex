defmodule Tickmark.AuditTrail.AuditEvent do
  @moduledoc """
  One append-only audit log row. The DB rejects UPDATE, DELETE and TRUNCATE.

  seq is an identity column the DB fills. `writable: :never` keeps Ecto from
  ever sending it, and `read_after_writes: true` reads it back on insert.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "audit_events" do
    field :seq, :integer, read_after_writes: true, writable: :never
    field :actor_type, Ecto.Enum, values: [:user, :agent, :system]
    field :actor_id, :string
    field :action, :string
    field :subject_type, :string
    field :subject_id, :binary_id
    field :payload, :map, default: %{}

    belongs_to :engagement, Tickmark.Engagements.Engagement

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  Builds an insert changeset from `%{actor: {type, id}, ...}`. All values come
  from application code, never from request params.
  """
  def changeset(%{actor: {actor_type, actor_id}} = attrs) do
    attrs =
      attrs
      |> Map.delete(:actor)
      |> Map.merge(%{actor_type: actor_type, actor_id: to_string(actor_id)})

    %__MODULE__{}
    |> cast(attrs, [
      :engagement_id,
      :actor_type,
      :actor_id,
      :action,
      :subject_type,
      :subject_id,
      :payload
    ])
    |> validate_required([:actor_type, :actor_id, :action, :subject_type, :subject_id, :payload])
    |> validate_format(:action, ~r/\A[a-z_]+\.[a-z_]+\z/)
    |> validate_change(:payload, &validate_string_keys/2)
    |> foreign_key_constraint(:engagement_id)
    |> check_constraint(:actor_type, name: :actor_type_valid)
  end

  # jsonb turns atom keys into strings on the way back. Requiring strings up
  # front keeps what was written and what is read identical.
  defp validate_string_keys(:payload, payload) do
    if Enum.all?(Map.keys(payload), &is_binary/1),
      do: [],
      else: [payload: "keys must be strings"]
  end
end
