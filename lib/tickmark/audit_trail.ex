defmodule Tickmark.AuditTrail do
  @moduledoc """
  Append-only audit log. There are no update or delete functions on purpose,
  and the DB triggers reject them anyway.

  State changes append their event inside the same `Ecto.Multi`, so the change
  and its evidence commit or roll back together.
  """
  alias Ecto.Multi
  alias Tickmark.Accounts.Scope
  alias Tickmark.AuditTrail.AuditEvent
  alias Tickmark.Engagements
  alias Tickmark.Repo

  @type actor :: {:user, Ecto.UUID.t()} | {:agent, String.t()} | {:system, String.t()}

  @spec actor(Scope.t()) :: actor()
  def actor(%Scope{user: %{id: user_id}}), do: {:user, user_id}

  @doc """
  Adds an audit event insert to `multi`. `fun` receives the earlier Multi
  results, so the event can reference rows inserted in the same transaction.
  """
  @spec append(Multi.t(), Multi.name(), (map() -> map())) :: Multi.t()
  def append(%Multi{} = multi, name, fun) when is_function(fun, 1) do
    Multi.insert(multi, name, fn changes -> AuditEvent.changeset(fun.(changes)) end)
  end

  @doc """
  Records a standalone event that has no other change to commit with it,
  for example a denied self-review.
  """
  @spec record(map()) :: {:ok, AuditEvent.t()} | {:error, Ecto.Changeset.t()}
  def record(attrs) do
    attrs
    |> AuditEvent.changeset()
    |> Repo.insert()
  end

  @doc """
  Tells the engagement's screens that an event was appended (design doc 6).
  Call it only after the transaction that inserted the event has committed.
  An event without an engagement has no topic and is not broadcast.
  """
  @spec broadcast_appended(AuditEvent.t()) :: :ok
  def broadcast_appended(%AuditEvent{engagement_id: nil}), do: :ok

  def broadcast_appended(%AuditEvent{} = event) do
    Engagements.broadcast(
      event.engagement_id,
      {:audit_appended,
       %{
         seq: event.seq,
         action: event.action,
         actor_type: event.actor_type,
         subject_type: event.subject_type,
         subject_id: event.subject_id,
         entry_number: event.payload["entry_number"]
       }}
    )
  end
end
