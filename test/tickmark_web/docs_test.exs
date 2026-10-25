defmodule TickmarkWeb.DocsTest do
  use ExUnit.Case, async: true

  alias TickmarkWeb.Docs

  test "the catalog holds the docs index, the root files and every file under docs" do
    ids = Enum.map(Docs.all(), & &1.id)
    docs_files = Path.wildcard("docs/**/*.{md,html}")

    assert Enum.take(ids, 4) == ["index", "readme", "tasks", "agents"]
    assert length(ids) == length(docs_files) + 3
    assert ids == Enum.uniq(ids)
    assert Enum.all?(Docs.all(), &(&1.title != ""))
  end

  test "every wiki link in a document points at a catalogued document" do
    for doc <- Docs.all(),
        doc.format == :markdown,
        [_, path] <-
          Regex.scan(
            ~r{data-phx-link="patch" data-phx-link-state="push" href="([^"#]+)},
            doc.body
          ) do
      id = path |> URI.decode() |> String.trim_leading("/docs") |> String.trim_leading("/")
      assert Docs.get(if(id == "", do: "index", else: id)), "#{doc.path} links to missing #{path}"
    end
  end

  test "groups follow the category order and list development logs newest first" do
    groups = Docs.groups()
    keys = Enum.map(groups, &elem(&1, 0))

    assert hd(keys) == "project"
    assert Enum.find_index(keys, &(&1 == "planning")) < Enum.find_index(keys, &(&1 == "devlog"))

    {_key, "개발 기록", devlogs} = List.keyfind(groups, "devlog", 0)
    dates = Enum.map(devlogs, &{&1.date, &1.seq})
    assert dates == Enum.sort(dates, :desc)
  end

  test "search matches titles first, then body text with a snippet" do
    [{first, nil} | _] = Docs.search("요구사항 명세서")
    assert first.title =~ "요구사항 명세서"

    assert [{_doc, %{match: match}} | _] = Docs.search("insert_all")
    assert String.downcase(match) == "insert_all"

    assert Docs.search("이런문서는없다zz") == []
  end

  test "html_file serves catalogued HTML documents only" do
    html_doc = Enum.find(Docs.all(), &(&1.format == :html))

    assert Docs.html_file(html_doc.path) =~ "<title>"
    assert Docs.html_file("docs/README.md") == nil
    assert Docs.html_file("docs/../mix.exs") == nil
  end
end
