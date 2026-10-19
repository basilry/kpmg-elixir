defmodule Tickmark.Engagements do
  @moduledoc """
  Engagements, their members and the access checks every other context uses.

  Every web-facing function in the other contexts calls `authorize/3` first.
  A user who is not a member gets `{:error, :forbidden}` whether or not the
  engagement exists, so ids cannot be probed.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Tickmark.Repo
  alias Tickmark.Accounts
  alias Tickmark.Accounts.Scope
  alias Tickmark.AuditTrail
  alias Tickmark.Engagements.{Engagement, Member, Policy}

  @type role :: Policy.role()

  @doc """
  Lists the engagements the user is a member of, newest first.

  Each engagement's `members` holds only the caller's own membership, so the
  list can show "my role" without one query per row. Use `list_members/2` for
  the full member list.
  """
  @spec list_engagements(Scope.t()) :: [Engagement.t()]
  def list_engagements(%Scope{user: %{id: user_id}}) do
    user_id
    |> member_engagements_query()
    |> order_by([e], desc: e.inserted_at, desc: e.id)
    |> Repo.all()
  end

  @doc """
  Gets one engagement the user is a member of, with the caller's membership in
  `members` like `list_engagements/1`.

  Raises `Ecto.NoResultsError` when the user is not a member, the engagement
  does not exist or the id is not a UUID. The three cases look the same, so ids
  cannot be probed, and Phoenix renders the error as a 404.
  """
  @spec get_engagement!(Scope.t(), Ecto.UUID.t()) :: Engagement.t()
  def get_engagement!(%Scope{user: %{id: user_id}}, id) do
    query = member_engagements_query(user_id)

    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.one!(where(query, [e], e.id == ^id))
      :error -> raise Ecto.NoResultsError, queryable: query
    end
  end

  @doc """
  Creates an engagement and makes the creator its preparer, in one transaction
  with the `engagement.created` audit event.

  `created_by_id` comes from the scope, never from `attrs`. On failure the
  changeset of the step that failed is returned and nothing is written.
  """
  @spec create_engagement(Scope.t(), map()) ::
          {:ok, Engagement.t()} | {:error, Ecto.Changeset.t()}
  def create_engagement(%Scope{user: %{id: user_id}} = scope, attrs) do
    Multi.new()
    |> Multi.insert(:engagement, Engagement.changeset(%Engagement{created_by_id: user_id}, attrs))
    |> Multi.insert(:member, fn %{engagement: engagement} ->
      Member.changeset(%Member{engagement_id: engagement.id, user_id: user_id}, %{
        role: :preparer
      })
    end)
    |> AuditTrail.append(:audit, fn %{engagement: engagement} ->
      %{
        engagement_id: engagement.id,
        actor: AuditTrail.actor(scope),
        action: "engagement.created",
        subject_type: "engagement",
        subject_id: engagement.id,
        payload: %{
          "client_name" => engagement.client_name,
          "fiscal_year" => engagement.fiscal_year,
          "period_end_date" => Date.to_iso8601(engagement.period_end_date),
          "performance_materiality" =>
            Decimal.to_string(engagement.performance_materiality, :normal)
        }
      }
    end)
    |> Repo.transact()
    |> case do
      {:ok, %{engagement: engagement, member: member, audit: event}} ->
        AuditTrail.broadcast_appended(event)
        {:ok, %{engagement | members: [member]}}

      {:error, _step, %Ecto.Changeset{} = changeset, _changes_so_far} ->
        {:error, changeset}
    end
  end

  @doc "Returns a changeset for the engagement form."
  @spec change_engagement(Engagement.t(), map()) :: Ecto.Changeset.t()
  def change_engagement(%Engagement{} = engagement, attrs \\ %{}) do
    Engagement.changeset(engagement, attrs)
  end

  @doc """
  Adds a registered user to the engagement. Only the engagement creator may do
  this.

  `role` may be the atom or its string form from a form; `Member.changeset/2`
  casts and validates it either way. A user who is already a member gets a
  changeset error on `:user_id`.
  """
  @spec add_member(Scope.t(), Engagement.t(), String.t(), role() | String.t()) ::
          {:ok, Member.t()} | {:error, :forbidden | :user_not_found | Ecto.Changeset.t()}
  def add_member(scope, %Engagement{id: engagement_id}, email, role) when is_binary(email) do
    with {:ok, _role} <- authorize(scope, engagement_id, :manage_members),
         {:ok, user} <- fetch_user_by_email(email) do
      Multi.new()
      |> Multi.insert(
        :member,
        Member.changeset(%Member{engagement_id: engagement_id, user_id: user.id}, %{role: role})
      )
      |> AuditTrail.append(:audit, fn %{member: member} ->
        %{
          engagement_id: engagement_id,
          actor: AuditTrail.actor(scope),
          action: "engagement.member_added",
          subject_type: "engagement",
          subject_id: engagement_id,
          payload: %{"user_id" => member.user_id, "role" => to_string(member.role)}
        }
      end)
      |> Repo.transact()
      |> case do
        {:ok, %{member: member, audit: event}} ->
          AuditTrail.broadcast_appended(event)
          {:ok, %{member | user: user}}

        {:error, _step, %Ecto.Changeset{} = changeset, _changes_so_far} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Lists every member of the engagement with the user preloaded, oldest first
  so the creator comes first.

  A caller without `:view` gets `[]`, the same as for an engagement that does
  not exist, so the return type stays a plain list.
  """
  @spec list_members(Scope.t(), Engagement.t()) :: [Member.t()]
  def list_members(scope, %Engagement{id: engagement_id}) do
    case authorize(scope, engagement_id, :view) do
      {:ok, _role} ->
        Repo.all(
          from m in Member,
            where: m.engagement_id == ^engagement_id,
            order_by: [asc: m.inserted_at, asc: m.id],
            preload: :user
        )

      {:error, :forbidden} ->
        []
    end
  end

  @doc """
  Returns the user's role in the engagement. Malformed ids are treated like
  missing memberships because they usually come straight from the URL.
  """
  @spec fetch_role(Scope.t(), Ecto.UUID.t()) :: {:ok, role()} | {:error, :forbidden}
  def fetch_role(%Scope{user: %{id: user_id}}, engagement_id) do
    with {:ok, engagement_id} <- Ecto.UUID.cast(engagement_id),
         role when not is_nil(role) <- Repo.one(role_query(engagement_id, user_id)) do
      {:ok, role}
    else
      _ -> {:error, :forbidden}
    end
  end

  def fetch_role(_scope, _engagement_id), do: {:error, :forbidden}

  @doc """
  Checks membership and the role policy. `:manage_members` is allowed only for
  the engagement creator, whatever the role table says.
  """
  @spec authorize(Scope.t(), Ecto.UUID.t(), Policy.action()) ::
          {:ok, role()} | {:error, :forbidden}
  def authorize(scope, engagement_id, :manage_members) do
    with {:ok, role} <- fetch_role(scope, engagement_id),
         true <- creator?(scope, engagement_id) do
      {:ok, role}
    else
      _ -> {:error, :forbidden}
    end
  end

  def authorize(scope, engagement_id, action) do
    with {:ok, role} <- fetch_role(scope, engagement_id),
         true <- Policy.allowed?(role, action) do
      {:ok, role}
    else
      _ -> {:error, :forbidden}
    end
  end

  @doc "The PubSub topic for one engagement. Topic strings are built only here."
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(engagement_id), do: "engagement:#{engagement_id}"

  @doc "Subscribes the caller to the engagement topic after checking membership."
  @spec subscribe(Scope.t(), Ecto.UUID.t()) :: :ok | {:error, :forbidden}
  def subscribe(scope, engagement_id) do
    with {:ok, _role} <- authorize(scope, engagement_id, :view) do
      Phoenix.PubSub.subscribe(Tickmark.PubSub, topic(engagement_id))
    end
  end

  @doc """
  Broadcasts a small message map to the engagement topic. Callers broadcast
  only after their transaction has committed.
  """
  @spec broadcast(Ecto.UUID.t(), tuple()) :: :ok
  def broadcast(engagement_id, message) when is_tuple(message) do
    Phoenix.PubSub.broadcast(Tickmark.PubSub, topic(engagement_id), message)
  end

  # Joins the caller's membership row and preloads it into `members`. The
  # unique index on (engagement_id, user_id) keeps it to one row per engagement.
  defp member_engagements_query(user_id) do
    from e in Engagement,
      join: m in assoc(e, :members),
      on: m.user_id == ^user_id,
      preload: [members: m]
  end

  defp fetch_user_by_email(email) do
    case Accounts.get_user_by_email(String.trim(email)) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  defp role_query(engagement_id, user_id) do
    from m in Member,
      where: m.engagement_id == ^engagement_id and m.user_id == ^user_id,
      select: m.role
  end

  defp creator?(%Scope{user: %{id: user_id}}, engagement_id) do
    Repo.exists?(
      from e in Engagement, where: e.id == ^engagement_id and e.created_by_id == ^user_id
    )
  end
end
