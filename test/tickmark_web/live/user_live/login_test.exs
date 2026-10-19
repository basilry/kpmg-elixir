defmodule TickmarkWeb.UserLive.LoginTest do
  use TickmarkWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tickmark.AccountsFixtures

  describe "login page" do
    test "renders login page", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      assert has_element?(lv, "#login-title", "로그인")
      assert page_title(lv) == "로그인 | Tickmark"
      assert has_element?(lv, "#registration-link", "회원가입")
      assert has_element?(lv, "#login_form_magic")
      assert has_element?(lv, "#login_form_password")
      assert has_element?(lv, "#login-magic-submit", "로그인 링크 받기")
      assert has_element?(lv, "#login-password-submit", "비밀번호로 로그인")
      assert has_element?(lv, "#login_form_password label", "로그인 상태 유지")
    end
  end

  describe "user login - magic link" do
    test "sends magic link email when user exists", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", user: %{email: user.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "등록된 이메일이라면 로그인 링크를 보냈습니다. 메일함을 확인하세요."

      assert Tickmark.Repo.get_by!(Tickmark.Accounts.UserToken, user_id: user.id).context ==
               "login"
    end

    test "does not disclose if user is registered", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", user: %{email: "idonotexist@example.com"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "등록된 이메일이라면 로그인 링크를 보냈습니다. 메일함을 확인하세요."
    end
  end

  describe "user login - password" do
    test "redirects if user logs in with valid credentials", %{conn: conn} do
      user = user_fixture() |> set_password()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form_password",
          user: %{email: user.email, password: valid_user_password(), remember_me: true}
        )

      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/"
      assert conn.resp_cookies["_tickmark_web_user_remember_me"]
    end

    test "does not remember the user when the checkbox is unchecked", %{conn: conn} do
      user = user_fixture() |> set_password()
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form_password",
          user: %{email: user.email, password: valid_user_password(), remember_me: false}
        )

      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)
      refute conn.resp_cookies["_tickmark_web_user_remember_me"]
    end

    test "redirects to login page with a flash error if credentials are invalid", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form_password", user: %{email: "test@email.com", password: "123456"})

      render_submit(form, %{user: %{remember_me: true}})

      conn = follow_trigger_action(form, conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "이메일 또는 비밀번호가 맞지 않습니다."
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "login navigation" do
    test "redirects to registration page when the Register button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _login_live, login_html} =
        lv
        |> element("#registration-link")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/register")

      assert login_html =~ "회원가입"
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      user = user_fixture()
      %{user: user, conn: log_in_user(conn, user)}
    end

    test "shows login page with email filled in", %{conn: conn, user: user} do
      {:ok, lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "계속하려면 다시 로그인하세요."
      refute has_element?(lv, "#registration-link")
      assert html =~ "로그인 링크 받기"

      assert html =~
               ~s(<input type="email" name="user[email]" id="login_form_magic_email" value="#{user.email}")
    end
  end
end
