defmodule TickmarkWeb.Docs.MarkdownTest do
  use ExUnit.Case, async: true

  alias TickmarkWeb.Docs.Markdown

  @source "docs/devlog/2026-01-02-1-log.md"
  @ids %{
    "docs/README.md" => "index",
    "docs/planning/2026-01-01-1-plan.md" => "planning/2026-01-01-1-plan"
  }

  defp html(markdown) do
    {html, _toc} = Markdown.render(markdown, @source, @ids)
    html
  end

  test "a link to a catalogued document opens it in the wiki and keeps the fragment" do
    html = html("[plan](../planning/2026-01-01-1-plan.md#scope)")

    assert html =~
             ~s(<a data-phx-link="patch" data-phx-link-state="push" href="/docs/planning/2026-01-01-1-plan#scope">)
  end

  test "a link to the docs index opens the wiki front page" do
    assert html("[index](../README.md)") =~ ~s(href="/docs">)
  end

  test "other repository files open on GitHub" do
    assert html("[code](../../lib/tickmark/ledger.ex)") =~
             ~s(href="https://github.com/basilry/kpmg-elixir/blob/main/lib/tickmark/ledger.ex")
  end

  test "external, absolute and in-page links stay as written" do
    html = html("[a](https://hexdocs.pm) [b](/engagements) [c](#scope)")

    assert html =~ ~s(href="https://hexdocs.pm")
    assert html =~ ~s(href="/engagements")
    assert html =~ ~s(href="#scope")
    refute html =~ "data-phx-link"
  end

  test "raw HTML and javascript links are dropped" do
    html = html("<script>alert(1)</script>\n\n[x](javascript:alert(1)) <b onclick=\"x\">b</b>")

    refute html =~ "<script"
    refute html =~ "onclick"
    refute html =~ "javascript:"
  end

  test "the table of contents lists h2 and h3 with the ids in the page" do
    {html, toc} = Markdown.render("# 제목\n\n## 두 번째 절\n\n### A & B\n\n#### 넣지 않음\n", @source, @ids)

    assert [%{level: 2, text: "두 번째 절"}, %{level: 3, text: "A & B"}] = toc
    for item <- toc, do: assert(html =~ ~s(id="#{item.id}"))
  end
end
