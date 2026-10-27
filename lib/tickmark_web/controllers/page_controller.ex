defmodule TickmarkWeb.PageController do
  use TickmarkWeb, :controller

  alias TickmarkWeb.UserAuth

  def home(conn, _params) do
    cond do
      conn.assigns.current_scope && conn.assigns.current_scope.user ->
        redirect(conn, to: ~p"/engagements")

      demo_user = demo_auto_login_user(conn) ->
        conn
        |> put_flash(
          :info,
          "데모 작성자 계정(#{demo_user.email})으로 자동 로그인했습니다. " <>
            "검토자로 보려면 로그아웃한 뒤 로그인하세요."
        )
        |> UserAuth.log_in_user(demo_user)

      true ->
        render(conn, :home, page_title: "분개 테스트")
    end
  end

  # The public demo logs visitors in as the demo preparer (config/prod.exs).
  # After an explicit log-out the session carries a flag, so the visitor sees
  # the home page and can log in as someone else instead.
  defp demo_auto_login_user(conn) do
    if Application.get_env(:tickmark, :demo_auto_login, false) and
         !get_session(conn, :demo_auto_login_off) do
      Tickmark.Demo.preparer()
    end
  end
end
