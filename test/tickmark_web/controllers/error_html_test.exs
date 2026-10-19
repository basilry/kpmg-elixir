defmodule TickmarkWeb.ErrorHTMLTest do
  use TickmarkWeb.ConnCase, async: true

  import Phoenix.Template, only: [render_to_string: 4]

  test "renders a complete Korean 404 page with a return link" do
    document = render_error("404")

    assert document |> LazyHTML.query("html") |> LazyHTML.attribute("lang") == ["ko"]

    assert document |> LazyHTML.query("link[rel=stylesheet]") |> LazyHTML.attribute("href") ==
             ["/assets/css/app.css"]

    assert document |> LazyHTML.query("#error-page h1") |> LazyHTML.text() == "페이지를 찾을 수 없습니다"

    assert document |> LazyHTML.query("#error-page") |> LazyHTML.text() =~
             "없는 주소이거나 내가 멤버가 아닌 감사 대상입니다."

    assert document |> LazyHTML.query("a[href='/engagements']") |> LazyHTML.text() == "감사 대상 목록으로"
  end

  test "renders a complete Korean 500 page without exposing the error" do
    html = render_to_string(TickmarkWeb.ErrorHTML, "500", "html", reason: "private error detail")
    document = LazyHTML.from_document(html)

    assert document |> LazyHTML.query("html") |> LazyHTML.attribute("lang") == ["ko"]

    assert document |> LazyHTML.query("link[rel=stylesheet]") |> LazyHTML.attribute("href") ==
             ["/assets/css/app.css"]

    assert document |> LazyHTML.query("#error-page h1") |> LazyHTML.text() == "문제가 생겼습니다"
    assert document |> LazyHTML.query("#error-page") |> LazyHTML.text() =~ "잠시 뒤 다시 시도해 주세요."
    refute html =~ "private error detail"
  end

  defp render_error(status) do
    TickmarkWeb.ErrorHTML
    |> render_to_string(status, "html", [])
    |> LazyHTML.from_document()
  end
end
