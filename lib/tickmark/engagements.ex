defmodule Tickmark.Engagements do
  @moduledoc """
  Engagements, their members and the access checks every other context uses.

  Every web-facing function in the other contexts calls `authorize/3` first.
  A user who is not a member gets `{:error, :forbidden}` whether or not the
  engagement exists, so ids cannot be probed.
  """

  import Ecto.Query, warn: false

  alias Tickmark.Repo
  alias Tickmark.Accounts.Scope
  alias Tickmark.Engagements.{Engagement, Member, Policy}

  @type role :: Policy.role()

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
