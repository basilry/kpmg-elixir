defmodule Tickmark.EngagementsFixtures do
  @moduledoc """
  Test helpers that go through `Tickmark.Engagements`, so the creator
  membership and the audit events exist the same way they do in the app.

  Values are synthetic only.
  """
  import Tickmark.AccountsFixtures

  alias Tickmark.Accounts.Scope
  alias Tickmark.Engagements

  def unique_client_name, do: "합성상사 #{System.unique_integer([:positive])}"

  def valid_engagement_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      client_name: unique_client_name(),
      fiscal_year: 2025,
      period_end_date: ~D[2025-12-31],
      performance_materiality: "225000000"
    })
  end

  @doc "Creates an engagement whose creator (and preparer) is the scope's user."
  def engagement_fixture(%Scope{} = scope, attrs \\ %{}) do
    {:ok, engagement} = Engagements.create_engagement(scope, valid_engagement_attributes(attrs))
    engagement
  end

  @doc """
  Adds `user` (a new user by default) to the engagement as `role`, acting as
  the engagement creator. Returns the member with `user` loaded.
  """
  def member_fixture(%Scope{} = creator_scope, engagement, role, user \\ user_fixture()) do
    {:ok, member} = Engagements.add_member(creator_scope, engagement, user.email, role)
    member
  end

  @doc "Adds a new user as `role` and returns that user's scope."
  def member_scope_fixture(%Scope{} = creator_scope, engagement, role) do
    member = member_fixture(creator_scope, engagement, role)
    Scope.for_user(member.user)
  end
end
