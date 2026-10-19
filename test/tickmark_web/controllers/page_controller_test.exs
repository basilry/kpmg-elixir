defmodule TickmarkWeb.PageControllerTest do
  use TickmarkWeb.ConnCase, async: true

  test "GET / introduces Tickmark with login and registration links", %{conn: conn} do
    conn = get(conn, ~p"/")
    document = conn |> html_response(200) |> LazyHTML.from_document()

    assert document |> LazyHTML.query("html") |> LazyHTML.attribute("lang") == ["ko"]
    assert document |> LazyHTML.query("title") |> LazyHTML.text() == "분개 테스트 | Tickmark"
    assert document |> LazyHTML.query("#home-title") |> LazyHTML.text() == "Tickmark"

    assert document |> LazyHTML.query("#home") |> LazyHTML.text() =~
             "감사인과 AI 에이전트가 함께 일하는 분개 테스트 작업 공간"

    assert document
           |> LazyHTML.query("#home-login[href='/users/log-in'].btn-primary")
           |> Enum.count() == 1

    assert document |> LazyHTML.query("#home-register[href='/users/register']") |> Enum.count() ==
             1

    assert document |> LazyHTML.query("#home-features > li") |> Enum.count() == 3
    assert document |> LazyHTML.query("#home") |> LazyHTML.text() =~ "모든 데이터는 합성 데이터입니다"
    refute document |> LazyHTML.query("body") |> LazyHTML.text() =~ "Phoenix"
  end

  test "GET / redirects a logged-in user to engagements", %{conn: conn} do
    %{conn: conn} = register_and_log_in_user(%{conn: conn})

    assert conn |> get(~p"/") |> redirected_to() == ~p"/engagements"
  end
end
