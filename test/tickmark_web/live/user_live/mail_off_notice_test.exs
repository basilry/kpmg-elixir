defmodule TickmarkWeb.UserLive.MailOffNoticeTest do
  # Not async: the mailer adapter is global application config.
  use TickmarkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  describe "with the test mailer" do
    test "neither page shows the mail-off notice", %{conn: conn} do
      {:ok, login, _html} = live(conn, ~p"/users/log-in")
      refute has_element?(login, "#mail-off-notice")

      {:ok, registration, _html} = live(conn, ~p"/users/register")
      refute has_element?(registration, "#mail-off-notice")
    end
  end

  # Production uses the Logger adapter (config/prod.exs) and sends no mail.
  describe "with the Logger mailer" do
    setup do
      previous = Application.get_env(:tickmark, Tickmark.Mailer)
      Application.put_env(:tickmark, Tickmark.Mailer, adapter: Swoosh.Adapters.Logger)
      on_exit(fn -> Application.put_env(:tickmark, Tickmark.Mailer, previous) end)
    end

    test "log-in page points to the demo account password", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      assert has_element?(lv, "#mail-off-notice", "메일을 보내지 않아")
      assert has_element?(lv, "#mail-off-notice", "데모 계정의 이메일과 비밀번호")
      refute has_element?(lv, "#local-mail-notice")
    end

    test "registration page says no login link will arrive", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      assert has_element?(lv, "#mail-off-notice", "로그인 링크를 받을 수 없습니다")
    end
  end
end
