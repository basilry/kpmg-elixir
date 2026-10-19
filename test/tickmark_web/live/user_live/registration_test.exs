defmodule TickmarkWeb.UserLive.RegistrationTest do
  use TickmarkWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tickmark.AccountsFixtures

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      assert has_element?(lv, "#registration-title", "회원가입")
      assert has_element?(lv, "#registration_form")
      assert has_element?(lv, "#login-link", "로그인")
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")
        |> follow_redirect(conn, ~p"/")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(user: %{"email" => "with spaces"})

      assert result =~ "회원가입"
      assert result =~ "공백 없이 @를 포함한 이메일을 입력하세요."
    end
  end

  describe "register user" do
    test "creates account but does not log in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()
      form = form(lv, "#registration_form", user: valid_user_attributes(email: email))

      {:ok, _lv, html} =
        render_submit(form)
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~
               "확인 메일을 #{email} 로 보냈습니다. 메일의 링크로 로그인하세요."
    end

    test "renders errors for duplicated email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      user = user_fixture(%{email: "test@email.com"})

      result =
        lv
        |> form("#registration_form",
          user: %{"email" => user.email}
        )
        |> render_submit()

      assert result =~ "이미 사용 중입니다."
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      {:ok, _login_live, login_html} =
        lv
        |> element("#login-link")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert login_html =~ "로그인"
    end
  end
end
