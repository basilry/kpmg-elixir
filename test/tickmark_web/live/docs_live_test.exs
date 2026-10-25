defmodule TickmarkWeb.DocsLiveTest do
  use TickmarkWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias TickmarkWeb.Docs
  alias TickmarkWeb.DocsLive.Components

  defp first_doc(category), do: Enum.find(Docs.all(), &(&1.category == category))

  test "the front page shows the docs index with the sidebar and the top bar link", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/docs")

    assert page_title(view) == "#{Docs.get("index").title} | Tickmark"
    assert has_element?(view, "#docs-group-project")
    assert has_element?(view, "#docs-group-devlog")
    assert has_element?(view, "#doc-body h1")
    assert has_element?(view, "#topbar-docs[aria-current=page]")
  end

  test "a sidebar link patches to the document", %{conn: conn} do
    doc = first_doc("planning")
    path = Components.doc_path(doc)
    {:ok, view, _html} = live(conn, ~p"/docs")

    view |> element(~s(#docs-group-planning a[href="#{path}"])) |> render_click()

    assert_patch(view, path)
    assert has_element?(view, "#doc-meta code", doc.path)
    assert has_element?(view, ~s(#docs-group-planning a[aria-current=page][href="#{path}"]))
    assert page_title(view) =~ doc.title
  end

  test "a document deep link renders its table of contents", %{conn: conn} do
    doc = Enum.find(Docs.all(), &(&1.toc != []))
    {:ok, view, _html} = live(conn, Components.doc_path(doc))

    item = hd(doc.toc)
    assert has_element?(view, ~s(#docs-toc a[href="##{item.id}"]))
    assert has_element?(view, ~s(#doc-body [id="#{item.id}"]))
  end

  test "links between documents stay inside the wiki", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/docs")

    assert has_element?(view, ~s(#doc-body a[data-phx-link=patch][href^="/docs/"]))
  end

  test "search lists matching documents and says when nothing matches", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/docs")

    view |> form("#docs-search", search: %{q: "요구사항"}) |> render_change()
    assert has_element?(view, "#docs-search-results li")
    refute has_element?(view, "#docs-groups")

    view |> form("#docs-search", search: %{q: "이런문서는없다zz"}) |> render_change()
    assert has_element?(view, "#docs-search-empty")

    view |> form("#docs-search", search: %{q: ""}) |> render_change()
    assert has_element?(view, "#docs-groups")
  end

  test "the list toggle opens the sidebar on narrow screens", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/docs")

    assert has_element?(view, "#docs-nav.hidden")
    view |> element("#docs-nav-toggle") |> render_click()
    assert has_element?(view, "#docs-nav-toggle[aria-expanded=true]")
    refute has_element?(view, "#docs-nav.hidden")
  end

  test "an HTML design document is shown in a sandboxed frame", %{conn: conn} do
    doc = Enum.find(Docs.all(), &(&1.format == :html))
    {:ok, view, _html} = live(conn, Components.doc_path(doc))

    src = Components.file_path(doc)
    assert has_element?(view, ~s(#doc-frame[sandbox="allow-scripts"][src="#{src}"]))
  end

  test "the design file is served with a sandbox policy", %{conn: conn} do
    doc = Enum.find(Docs.all(), &(&1.format == :html))
    conn = get(conn, Components.file_path(doc))

    assert html_response(conn, 200) =~ "<title>"
    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "sandbox allow-scripts"
  end

  test "unknown documents and files are 404", %{conn: conn} do
    assert_error_sent 404, fn -> get(conn, ~p"/docs/planning/none") end
    assert_error_sent 404, fn -> get(conn, ~p"/docs/files/README.md") end
    assert_error_sent 404, fn -> get(conn, ~p"/docs/files/none.html") end
  end

  describe "signed in" do
    setup :register_and_log_in_user

    test "the top bar links to the docs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/engagements")

      assert has_element?(view, ~s(#topbar-docs[href="/docs"]))
      refute has_element?(view, "#topbar-docs[aria-current]")
    end
  end
end
