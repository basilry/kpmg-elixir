defmodule TickmarkWeb.DemoAutoLoginTest do
  # Changes the application and OS environment, so it runs alone after the
  # async tests (ExUnit runs sync modules one at a time).
  use TickmarkWeb.ConnCase, async: false

  import Tickmark.AccountsFixtures

  alias Tickmark.Accounts

  @demo_email "kim.writer@example.com"

  setup do
    previous = Application.fetch_env(:tickmark, :demo_auto_login)
    Application.put_env(:tickmark, :demo_auto_login, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:tickmark, :demo_auto_login, value)
        :error -> Application.delete_env(:tickmark, :demo_auto_login)
      end
    end)
  end

  test "GET / logs a visitor in as the demo preparer", %{conn: conn} do
    demo_user = user_fixture(%{email: @demo_email})

    conn = get(conn, ~p"/")

    assert redirected_to(conn) == ~p"/"
    assert {session_user, _} = Accounts.get_user_by_session_token(get_session(conn, :user_token))
    assert session_user.id == demo_user.id
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ @demo_email

    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/engagements"

    conn = get(conn, ~p"/engagements")
    assert html_response(conn, 200) =~ "자동 로그인했습니다"
  end

  test "GET / shows the home page before the demo is seeded", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert html_response(conn, 200) =~ ~s(id="home-login")
    refute get_session(conn, :user_token)
  end

  test "GET / shows the home page when auto-login is off", %{conn: conn} do
    Application.put_env(:tickmark, :demo_auto_login, false)
    user_fixture(%{email: @demo_email})

    conn = get(conn, ~p"/")

    assert html_response(conn, 200) =~ ~s(id="home-login")
    refute get_session(conn, :user_token)
  end

  test "a visitor who logs out sees the home page instead of the demo user", %{conn: conn} do
    user_fixture(%{email: @demo_email})

    conn = conn |> get(~p"/") |> get(~p"/")
    assert redirected_to(conn) == ~p"/engagements"

    conn = delete(conn, ~p"/users/log-out")
    assert redirected_to(conn) == ~p"/"

    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ ~s(id="home-login")
    refute get_session(conn, :user_token)
  end

  test "production turns auto-login on" do
    config = Config.Reader.read!(config_path("prod.exs"), env: :prod)

    assert get_in(config, [:tickmark, :demo_auto_login]) == true
  end

  test "TICKMARK_DEMO_AUTO_LOGIN overrides the setting" do
    previous = System.get_env("TICKMARK_DEMO_AUTO_LOGIN")

    on_exit(fn ->
      if previous,
        do: System.put_env("TICKMARK_DEMO_AUTO_LOGIN", previous),
        else: System.delete_env("TICKMARK_DEMO_AUTO_LOGIN")
    end)

    for {value, expected} <- [{"false", false}, {"0", false}, {"true", true}, {"1", true}] do
      System.put_env("TICKMARK_DEMO_AUTO_LOGIN", value)

      assert runtime_auto_login() == expected, "TICKMARK_DEMO_AUTO_LOGIN=#{value}"
    end

    System.delete_env("TICKMARK_DEMO_AUTO_LOGIN")
    assert runtime_auto_login() == nil
  end

  # runtime.exs raises without DATABASE_URL in prod, so it is read as dev.
  # The override sits outside the prod block and applies the same way.
  defp runtime_auto_login do
    config_path("runtime.exs")
    |> Config.Reader.read!(env: :dev)
    |> get_in([:tickmark, :demo_auto_login])
  end

  defp config_path(file), do: Path.expand("../../../config/#{file}", __DIR__)
end
