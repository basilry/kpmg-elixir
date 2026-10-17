defmodule TickmarkWeb.EngagementLiveTest do
  use TickmarkWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tickmark.AccountsFixtures
  import Tickmark.EngagementsFixtures

  alias Tickmark.Engagements

  setup :register_and_log_in_user

  describe "Index (S1)" do
    test "lists only my engagements with my role", %{conn: conn, scope: scope} do
      mine =
        engagement_fixture(scope, %{
          client_name: "누리정밀 주식회사",
          performance_materiality: "225000000"
        })

      other_creator = user_scope_fixture()
      reviewing = engagement_fixture(other_creator, %{client_name: "한빛물산 주식회사"})
      member_fixture(other_creator, reviewing, :reviewer, scope.user)
      not_mine = engagement_fixture(other_creator, %{client_name: "다온유통 주식회사"})

      {:ok, view, html} = live(conn, ~p"/engagements")

      assert has_element?(view, "#engagements-#{mine.id}", "누리정밀 주식회사")
      assert has_element?(view, "#engagements-#{mine.id}", "FY2025")
      assert has_element?(view, "#engagements-#{mine.id}", "2025-12-31")
      assert has_element?(view, "#engagements-#{mine.id}", "225,000,000")
      assert has_element?(view, "#engagements-#{mine.id}", "작성자")

      assert has_element?(view, "#engagements-#{reviewing.id}", "한빛물산 주식회사")
      assert has_element?(view, "#engagements-#{reviewing.id}", "검토자")

      refute has_element?(view, "#engagements-#{not_mine.id}")
      refute html =~ "다온유통 주식회사"
    end

    test "shows the empty state when I have no engagements", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/engagements")

      assert has_element?(view, "#engagements-empty", "감사 대상이 없습니다.")
    end

    test "the new button opens the create panel and cancel closes it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/engagements")
      refute has_element?(view, "#engagement-form")

      view |> element("#new-engagement-button") |> render_click()
      assert_patch(view, ~p"/engagements/new")
      assert has_element?(view, "#engagement-form")

      view |> element("#engagement-form a", "취소") |> render_click()
      assert_patch(view, ~p"/engagements")
      refute has_element?(view, "#engagement-form")
    end

    test "shows validation errors while typing and on save", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/engagements/new")

      invalid = %{
        client_name: "",
        fiscal_year: "1999",
        period_end_date: "",
        performance_materiality: "0"
      }

      html = view |> form("#engagement-form", engagement: invalid) |> render_change()
      assert html =~ "can&#39;t be blank"
      assert html =~ "must be greater than or equal to 2000"
      assert html =~ "must be greater than 0"

      html = view |> form("#engagement-form", engagement: invalid) |> render_submit()
      assert html =~ "can&#39;t be blank"
      assert has_element?(view, "#engagement-form")
    end

    test "saving navigates to the new engagement", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/engagements/new")

      attrs = %{
        client_name: "누리정밀 주식회사",
        fiscal_year: "2025",
        period_end_date: "2025-12-31",
        performance_materiality: "225000000"
      }

      result = view |> form("#engagement-form", engagement: attrs) |> render_submit()

      assert [engagement] = Engagements.list_engagements(scope)
      {:ok, show_view, html} = follow_redirect(result, conn, ~p"/engagements/#{engagement}")

      assert html =~ "감사 대상을 만들었습니다."
      assert has_element?(show_view, "#engagement-overview", "225,000,000원")
      assert has_element?(show_view, "#members", scope.user.email)
    end
  end

  describe "Show (S2)" do
    test "the creator sees the overview, members, actions and empty sections", %{
      conn: conn,
      scope: scope
    } do
      engagement =
        engagement_fixture(scope, %{
          client_name: "누리정밀 주식회사",
          period_end_date: ~D[2025-12-31],
          performance_materiality: "225000000"
        })

      {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}")

      assert has_element?(view, "h1", "누리정밀 주식회사")
      assert has_element?(view, "#engagement-overview", "2025-12-31")
      assert has_element?(view, "#engagement-overview", "225,000,000원")

      assert has_element?(view, "#members", scope.user.email)
      assert has_element?(view, "#members", "작성자")
      assert has_element?(view, "#member-form")

      assert has_element?(
               view,
               "#import-link[href='#{~p"/engagements/#{engagement}/imports/new"}']",
               "GL 불러오기"
             )

      assert has_element?(view, "#audit-log-link[href='#{~p"/engagements/#{engagement}/audit"}']")

      assert has_element?(view, "#imports-empty", "아직 불러온 GL이 없습니다.")
      assert has_element?(view, "#test-runs-empty", "아직 테스트 실행이 없습니다.")
    end

    test "a non-member gets Ecto.NoResultsError", %{conn: conn} do
      engagement = engagement_fixture(user_scope_fixture())

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/engagements/#{engagement}")
      end
    end

    test "a malformed id gets Ecto.NoResultsError", %{conn: conn} do
      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/engagements/not-a-uuid")
      end
    end

    test "the creator adds a member and sees errors for unknown and existing emails", %{
      conn: conn,
      scope: scope
    } do
      engagement = engagement_fixture(scope)
      user = user_fixture()

      {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}")

      html =
        view
        |> form("#member-form", member: %{email: "nobody@example.com", role: "reviewer"})
        |> render_submit()

      assert html =~ "가입한 사용자 중 이 이메일이 없습니다."

      html =
        view
        |> form("#member-form", member: %{email: user.email, role: "reviewer"})
        |> render_submit()

      assert html =~ "멤버를 추가했습니다."
      assert [_creator, member] = Engagements.list_members(scope, engagement)
      assert has_element?(view, "#members-#{member.id}", user.email)
      assert has_element?(view, "#members-#{member.id}", "검토자")

      html =
        view
        |> form("#member-form", member: %{email: user.email, role: "preparer"})
        |> render_submit()

      assert html =~ "이미 이 감사 대상의 멤버입니다."
      assert length(Engagements.list_members(scope, engagement)) == 2
    end

    test "a reviewer sees the members and the audit log link but no member form or GL import", %{
      conn: conn,
      scope: scope
    } do
      creator = user_scope_fixture()
      engagement = engagement_fixture(creator)
      member_fixture(creator, engagement, :reviewer, scope.user)

      {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}")

      assert has_element?(view, "#members", creator.user.email)
      assert has_element?(view, "#members", scope.user.email)
      refute has_element?(view, "#member-form")
      refute has_element?(view, "#import-link")
      assert has_element?(view, "#audit-log-link")
    end

    test "a preparer who is not the creator gets the GL import link but no member form", %{
      conn: conn,
      scope: scope
    } do
      creator = user_scope_fixture()
      engagement = engagement_fixture(creator)
      member_fixture(creator, engagement, :preparer, scope.user)

      {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}")

      assert has_element?(view, "#import-link")
      refute has_element?(view, "#member-form")
    end

    test "a hand-crafted add_member event from a reviewer is refused", %{
      conn: conn,
      scope: scope
    } do
      creator = user_scope_fixture()
      engagement = engagement_fixture(creator)
      member_fixture(creator, engagement, :reviewer, scope.user)
      outsider = user_fixture()

      {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}")

      html =
        render_hook(view, "add_member", %{
          "member" => %{"email" => outsider.email, "role" => "reviewer"}
        })

      assert html =~ "멤버를 추가할 권한이 없습니다."
      assert length(Engagements.list_members(creator, engagement)) == 2
    end

    test "engagement topic messages keep the screen running", %{conn: conn, scope: scope} do
      engagement = engagement_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}")

      id = Ecto.UUID.generate()

      :ok =
        Engagements.broadcast(
          engagement.id,
          {:import_updated, %{import_id: id, status: :completed, entry_count: 10, error_count: 0}}
        )

      :ok =
        Engagements.broadcast(
          engagement.id,
          {:test_run_updated, %{test_run_id: id, status: :completed, finding_count: 0}}
        )

      :ok =
        Engagements.broadcast(
          engagement.id,
          {:finding_updated, %{finding_id: id, status: :open, triage_status: :pending}}
        )

      :ok =
        Engagements.broadcast(
          engagement.id,
          {:audit_appended, %{seq: 1, action: "engagement.created"}}
        )

      assert render(view) =~ engagement.client_name
      assert Process.alive?(view.pid)
    end
  end
end
