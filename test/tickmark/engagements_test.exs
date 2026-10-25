defmodule Tickmark.EngagementsTest do
  use Tickmark.DataCase, async: true

  import Tickmark.AccountsFixtures
  import Tickmark.EngagementsFixtures

  alias Tickmark.Accounts.Scope
  alias Tickmark.AuditTrail.AuditEvent
  alias Tickmark.Engagements
  alias Tickmark.Engagements.{Engagement, Member}

  defp audit_events(action) do
    Repo.all(from e in AuditEvent, where: e.action == ^action, order_by: e.seq)
  end

  describe "create_engagement/2" do
    test "creates the engagement, the preparer membership and the audit event" do
      scope = user_scope_fixture()
      subscribe_on_creation()

      attrs =
        valid_engagement_attributes(%{
          client_name: "누리정밀 주식회사",
          performance_materiality: "225000000"
        })

      assert {:ok, %Engagement{} = engagement} = Engagements.create_engagement(scope, attrs)
      assert engagement.client_name == "누리정밀 주식회사"
      assert engagement.fiscal_year == 2025
      assert engagement.period_end_date == ~D[2025-12-31]
      assert Decimal.equal?(engagement.performance_materiality, 225_000_000)
      assert engagement.created_by_id == scope.user.id

      assert [%Member{role: :preparer} = member] = engagement.members
      assert member.user_id == scope.user.id
      assert Engagements.fetch_role(scope, engagement.id) == {:ok, :preparer}

      assert [event] = audit_events("engagement.created")
      assert event.engagement_id == engagement.id
      assert event.actor_type == :user
      assert event.actor_id == scope.user.id
      assert event.subject_type == "engagement"
      assert event.subject_id == engagement.id

      assert event.payload == %{
               "client_name" => "누리정밀 주식회사",
               "fiscal_year" => 2025,
               "period_end_date" => "2025-12-31",
               "performance_materiality" => "225000000"
             }

      assert_audit_appended(event)
      refute_received {:audit_appended, _}
    end

    test "takes created_by_id from the scope, not from attrs" do
      scope = user_scope_fixture()
      other_user = user_fixture()

      attrs = valid_engagement_attributes(%{created_by_id: other_user.id})
      assert {:ok, engagement} = Engagements.create_engagement(scope, attrs)

      assert engagement.created_by_id == scope.user.id

      assert Engagements.fetch_role(Scope.for_user(other_user), engagement.id) ==
               {:error, :forbidden}
    end

    test "returns the failing changeset and writes nothing on invalid attrs" do
      scope = user_scope_fixture()
      subscribe_on_creation()

      attrs = %{client_name: "", fiscal_year: 1999, performance_materiality: "0"}
      assert {:error, %Ecto.Changeset{} = changeset} = Engagements.create_engagement(scope, attrs)

      errors = errors_on(changeset)
      assert errors.client_name == ["회사명을 입력하세요."]
      assert errors.period_end_date == ["결산일을 선택하세요."]
      assert errors.fiscal_year == ["2000에서 2100 사이로 입력하세요."]
      assert errors.performance_materiality == ["0보다 큰 금액을 입력하세요."]

      assert Repo.aggregate(Engagement, :count) == 0
      assert Repo.aggregate(Member, :count) == 0
      assert Repo.aggregate(AuditEvent, :count) == 0
      refute_received {:audit_appended, _}
    end
  end

  describe "change_engagement/2" do
    test "returns a changeset for the form" do
      assert %Ecto.Changeset{valid?: false} = Engagements.change_engagement(%Engagement{})

      changeset = Engagements.change_engagement(%Engagement{}, valid_engagement_attributes())
      assert changeset.valid?
    end
  end

  describe "list_engagements/1" do
    test "returns only the user's engagements, newest first, with the user's role" do
      creator = user_scope_fixture()
      reviewer = user_scope_fixture()
      outsider = user_scope_fixture()

      first = engagement_fixture(creator)
      second = engagement_fixture(creator)
      _others = engagement_fixture(outsider)
      member_fixture(creator, first, :reviewer, reviewer.user)

      assert [%{id: second_id}, %{id: first_id}] = Engagements.list_engagements(creator)
      assert {second_id, first_id} == {second.id, first.id}

      assert [listed] = Engagements.list_engagements(reviewer)
      assert listed.id == first.id
      assert [%Member{role: :reviewer}] = listed.members
    end

    test "returns an empty list for a user with no memberships" do
      creator = user_scope_fixture()
      engagement_fixture(creator)

      assert Engagements.list_engagements(user_scope_fixture()) == []
    end
  end

  describe "get_engagement!/2" do
    setup do
      creator = user_scope_fixture()
      %{creator: creator, engagement: engagement_fixture(creator)}
    end

    test "returns the engagement with the caller's membership", %{
      creator: creator,
      engagement: engagement
    } do
      reviewer = member_scope_fixture(creator, engagement, :reviewer)

      assert %Engagement{members: [%Member{role: :preparer}]} =
               Engagements.get_engagement!(creator, engagement.id)

      assert %Engagement{members: [%Member{role: :reviewer}]} =
               Engagements.get_engagement!(reviewer, engagement.id)
    end

    test "raises Ecto.NoResultsError for a non-member", %{engagement: engagement} do
      assert_raise Ecto.NoResultsError, fn ->
        Engagements.get_engagement!(user_scope_fixture(), engagement.id)
      end
    end

    test "raises Ecto.NoResultsError for an unknown id", %{creator: creator} do
      assert_raise Ecto.NoResultsError, fn ->
        Engagements.get_engagement!(creator, Ecto.UUID.generate())
      end
    end

    test "raises Ecto.NoResultsError for a malformed id", %{creator: creator} do
      assert_raise Ecto.NoResultsError, fn ->
        Engagements.get_engagement!(creator, "not-a-uuid")
      end
    end
  end

  describe "add_member/4" do
    setup do
      creator = user_scope_fixture()
      %{creator: creator, engagement: engagement_fixture(creator)}
    end

    test "the creator adds a reviewer and an audit event is written", %{
      creator: creator,
      engagement: engagement
    } do
      user = user_fixture()
      :ok = Engagements.subscribe(creator, engagement.id)

      assert {:ok, %Member{} = member} =
               Engagements.add_member(creator, engagement, user.email, :reviewer)

      assert member.role == :reviewer
      assert member.user.id == user.id
      assert Engagements.fetch_role(Scope.for_user(user), engagement.id) == {:ok, :reviewer}

      assert [event] = audit_events("engagement.member_added")
      assert event.engagement_id == engagement.id
      assert event.actor_type == :user
      assert event.actor_id == creator.user.id
      assert event.subject_type == "engagement"
      assert event.subject_id == engagement.id
      assert event.payload == %{"user_id" => user.id, "role" => "reviewer"}
      assert_audit_appended(event)
      refute_received {:audit_appended, _}
    end

    test "refused and invalid member additions do not broadcast", %{
      creator: creator,
      engagement: engagement
    } do
      user = user_fixture()
      :ok = Engagements.subscribe(creator, engagement.id)

      assert {:error, :forbidden} =
               Engagements.add_member(user_scope_fixture(), engagement, user.email, :reviewer)

      assert {:error, :user_not_found} =
               Engagements.add_member(creator, engagement, "missing@example.com", :reviewer)

      assert {:error, %Ecto.Changeset{}} =
               Engagements.add_member(creator, engagement, user.email, "admin")

      assert {:ok, _member} = Engagements.add_member(creator, engagement, user.email, :reviewer)
      assert [event] = audit_events("engagement.member_added")
      assert_audit_appended(event)

      assert {:error, %Ecto.Changeset{}} =
               Engagements.add_member(creator, engagement, user.email, :preparer)

      refute_received {:audit_appended, _}
    end

    test "accepts the role as a form string and trims the email", %{
      creator: creator,
      engagement: engagement
    } do
      user = user_fixture()
      email = "  " <> String.upcase(user.email) <> " "

      assert {:ok, member} = Engagements.add_member(creator, engagement, email, "preparer")
      assert member.user_id == user.id
      assert member.role == :preparer
    end

    test "returns :user_not_found for an unknown email", %{
      creator: creator,
      engagement: engagement
    } do
      assert Engagements.add_member(creator, engagement, "nobody@example.com", :reviewer) ==
               {:error, :user_not_found}

      assert audit_events("engagement.member_added") == []
    end

    test "returns a changeset error for an existing member", %{
      creator: creator,
      engagement: engagement
    } do
      member = member_fixture(creator, engagement, :reviewer)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Engagements.add_member(creator, engagement, member.user.email, :preparer)

      assert errors_on(changeset).user_id == ["has already been taken"]
      assert length(audit_events("engagement.member_added")) == 1

      assert Engagements.fetch_role(Scope.for_user(member.user), engagement.id) ==
               {:ok, :reviewer}
    end

    test "returns a changeset error for an unknown role", %{
      creator: creator,
      engagement: engagement
    } do
      user = user_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Engagements.add_member(creator, engagement, user.email, "admin")

      assert errors_on(changeset).role == ["is invalid"]
      assert audit_events("engagement.member_added") == []
    end

    test "a preparer who did not create the engagement is forbidden", %{
      creator: creator,
      engagement: engagement
    } do
      preparer = member_scope_fixture(creator, engagement, :preparer)

      assert Engagements.add_member(preparer, engagement, user_fixture().email, :reviewer) ==
               {:error, :forbidden}
    end

    test "a reviewer is forbidden", %{creator: creator, engagement: engagement} do
      reviewer = member_scope_fixture(creator, engagement, :reviewer)

      assert Engagements.add_member(reviewer, engagement, user_fixture().email, :reviewer) ==
               {:error, :forbidden}
    end

    test "a non-member is forbidden before the email is looked up", %{engagement: engagement} do
      outsider = user_scope_fixture()

      assert Engagements.add_member(outsider, engagement, "nobody@example.com", :reviewer) ==
               {:error, :forbidden}
    end
  end

  describe "list_members/2" do
    setup do
      creator = user_scope_fixture()
      %{creator: creator, engagement: engagement_fixture(creator)}
    end

    test "lists members oldest first with users loaded", %{
      creator: creator,
      engagement: engagement
    } do
      reviewer = member_fixture(creator, engagement, :reviewer)

      assert [first, second] = Engagements.list_members(creator, engagement)
      assert {first.user.email, first.role} == {creator.user.email, :preparer}
      assert {second.user.email, second.role} == {reviewer.user.email, :reviewer}
    end

    test "a reviewer can list the members", %{creator: creator, engagement: engagement} do
      reviewer = member_scope_fixture(creator, engagement, :reviewer)

      assert length(Engagements.list_members(reviewer, engagement)) == 2
    end

    test "a non-member gets an empty list", %{engagement: engagement} do
      assert Engagements.list_members(user_scope_fixture(), engagement) == []
    end
  end

  # The id is generated inside create_engagement/2. Subscribe as soon as its
  # INSERT returns, while the membership and event still have to commit.
  # The query's UUID parameters include the new id and the creator's id;
  # subscribing to both avoids depending on their SQL parameter positions.
  defp subscribe_on_creation do
    handler = {__MODULE__, self()}

    :ok =
      :telemetry.attach(
        handler,
        [:tickmark, :repo, :query],
        fn _, _, metadata, owner ->
          if self() == owner and metadata.source == "engagements" and
               String.starts_with?(metadata.query, "INSERT") do
            for param <- metadata.params, is_binary(param), byte_size(param) == 16 do
              {:ok, id} = Ecto.UUID.load(param)
              :ok = Phoenix.PubSub.subscribe(Tickmark.PubSub, Engagements.topic(id))
            end
          end
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp assert_audit_appended(event) do
    assert_receive {:audit_appended, message}

    assert message == %{
             seq: event.seq,
             action: event.action,
             actor_type: :user,
             subject_type: "engagement",
             subject_id: event.subject_id,
             entry_number: nil
           }
  end
end
