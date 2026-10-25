defmodule TickmarkWeb.PageController do
  use TickmarkWeb, :controller

  def home(conn, _params) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      redirect(conn, to: ~p"/engagements")
    else
      render(conn, :home, page_title: "분개 테스트")
    end
  end
end
