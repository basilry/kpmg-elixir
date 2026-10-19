defmodule Tickmark.Engagements.AuthorizationTest do
  use Tickmark.DataCase, async: true

  import Tickmark.AccountsFixtures
  import Tickmark.SchemaFixtures

  alias Tickmark.Accounts.Scope
  alias Tickmark.Engagements

  setup do
    creator = user_fixture()
    reviewer = user_fixture()
    engagement = insert_engagement(creator)
    insert_member(engagement, creator, :preparer)
    insert_member(engagement, reviewer, :reviewer)

    %{
      engagement: engagement,
      creator: Scope.for_user(creator),
      reviewer: Scope.for_user(reviewer),
      outsider: user_scope_fixture()
    }
  end

  describe "fetch_role/2" do
    test "returns the member's role", ctx do
      assert Engagements.fetch_role(ctx.creator, ctx.engagement.id) == {:ok, :preparer}
      assert Engagements.fetch_role(ctx.reviewer, ctx.engagement.id) == {:ok, :reviewer}
    end

    test "forbids non-members, unknown ids, malformed ids and missing scopes", ctx do
      assert Engagements.fetch_role(ctx.outsider, ctx.engagement.id) == {:error, :forbidden}
      assert Engagements.fetch_role(ctx.creator, Ecto.UUID.generate()) == {:error, :forbidden}
      assert Engagements.fetch_role(ctx.creator, "not-a-uuid") == {:error, :forbidden}
      assert Engagements.fetch_role(nil, ctx.engagement.id) == {:error, :forbidden}
    end
  end

  describe "authorize/3" do
    test "follows the policy table", ctx do
      assert Engagements.authorize(ctx.creator, ctx.engagement.id, :import_ledger) ==
               {:ok, :preparer}

      assert Engagements.authorize(ctx.reviewer, ctx.engagement.id, :import_ledger) ==
               {:error, :forbidden}

      assert Engagements.authorize(ctx.reviewer, ctx.engagement.id, :review_conclusion) ==
               {:ok, :reviewer}

      assert Engagements.authorize(ctx.outsider, ctx.engagement.id, :view) ==
               {:error, :forbidden}
    end

    test "allows :manage_members only for the creator", ctx do
      other_preparer = user_fixture()
      insert_member(ctx.engagement, other_preparer, :preparer)

      assert Engagements.authorize(ctx.creator, ctx.engagement.id, :manage_members) ==
               {:ok, :preparer}

      assert Engagements.authorize(
               Scope.for_user(other_preparer),
               ctx.engagement.id,
               :manage_members
             ) == {:error, :forbidden}

      assert Engagements.authorize(ctx.reviewer, ctx.engagement.id, :manage_members) ==
               {:error, :forbidden}
    end
  end

  describe "subscribe/2 and broadcast/2" do
    test "members receive messages on the engagement topic", ctx do
      assert :ok = Engagements.subscribe(ctx.reviewer, ctx.engagement.id)

      message = {:import_updated, %{import_id: Ecto.UUID.generate(), status: :succeeded}}
      assert :ok = Engagements.broadcast(ctx.engagement.id, message)
      assert_receive ^message
    end

    test "non-members cannot subscribe", ctx do
      assert Engagements.subscribe(ctx.outsider, ctx.engagement.id) == {:error, :forbidden}
    end

    test "topic/1 builds the contract topic string", ctx do
      assert Engagements.topic(ctx.engagement.id) == "engagement:#{ctx.engagement.id}"
    end
  end
end
