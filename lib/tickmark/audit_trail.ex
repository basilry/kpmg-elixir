defmodule Tickmark.AuditTrail do
  @moduledoc """
  Append-only audit log. There are no update or delete functions on purpose,
  and the DB triggers reject them anyway.

  State changes append their event inside the same `Ecto.Multi`, so the change
  and its evidence commit or roll back together.
  """
  import Ecto.Query, warn: false

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

  @doc """
  Lists an engagement's events newest first, after checking `:view` access.

  Filters are combined with AND: `:before_seq` (integer), `:actor_type`,
  `:subject` (`{type, uuid}`) and `:entry_number` (a nonempty string in payload).
  `:limit` defaults to 50 and integers are clamped to 1..200. Unknown options
  and invalid filter values are ignored; an invalid limit uses the default.
  Non-members, missing engagements and malformed engagement ids return `[]`.
  """
  @spec list_events(Scope.t(), Ecto.UUID.t(), keyword()) :: [AuditEvent.t()]
  def list_events(scope, engagement_id, opts \\ []) do
    case Engagements.authorize(scope, engagement_id, :view) do
      {:ok, _role} ->
        query =
          from event in AuditEvent,
            where: event.engagement_id == ^engagement_id,
            order_by: [desc: event.seq],
            limit: ^event_limit(Keyword.get(opts, :limit, 50))

        opts
        |> Enum.reduce(query, &filter_events/2)
        |> Repo.all()

      {:error, :forbidden} ->
        []
    end
  end

  defp event_limit(value) when is_integer(value), do: value |> max(1) |> min(200)
  defp event_limit(_value), do: 50

  defp filter_events({:before_seq, seq}, query) when is_integer(seq),
    do: where(query, [event], event.seq < ^seq)

  defp filter_events({:actor_type, type}, query) when type in [:user, :agent, :system],
    do: where(query, [event], event.actor_type == ^type)

  defp filter_events({:subject, {type, id}}, query) when is_binary(type) and type != "" do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> where(query, [event], event.subject_type == ^type and event.subject_id == ^id)
      :error -> query
    end
  end

  defp filter_events({:entry_number, value}, query) when is_binary(value) and value != "",
    do: where(query, [event], fragment("?->>'entry_number' = ?", event.payload, ^value))

  defp filter_events(_option, query), do: query
end
