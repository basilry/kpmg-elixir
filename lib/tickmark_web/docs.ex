defmodule TickmarkWeb.Docs do
  @moduledoc """
  Catalog of the project documents shown in the docs wiki (`/docs`).

  Documents are read and rendered when this module compiles. The wiki then
  works in a release without the docs folder, and a request can only reach
  documents in this list: no path from a URL ever touches the disk.
  Editing a file recompiles this module (`@external_resource`), and adding or
  removing one is caught by `__mix_recompile__?/0`.
  """

  alias TickmarkWeb.Docs.{Document, Loader, Markdown}

  @root Path.expand("../..", __DIR__)
  @paths Loader.paths(@root)

  for path <- @paths, do: @external_resource(Path.join(@root, path))

  @documents Loader.build(@root, @paths)

  @categories [
    {"project", "프로젝트"},
    {"planning", "기획"},
    {"architecture", "설계"},
    {"design", "디자인"},
    {"domain", "도메인"},
    {"devlog", "개발 기록"}
  ]

  @max_results 30
  @snippet_before 24
  @snippet_length 90

  @doc false
  def __mix_recompile__?, do: Loader.paths(@root) != @paths

  @doc "Every document in display order."
  def all, do: @documents

  @doc "The document with wiki id `id`, or nil."
  def get(id), do: Enum.find(all(), &(&1.id == id))

  @doc "The contents of a catalogued HTML document by repository path, or nil."
  def html_file(path) do
    Enum.find_value(all(), fn
      %Document{format: :html, path: ^path, body: body} -> body
      _document -> nil
    end)
  end

  @doc "GitHub address of a document's source file."
  def github_url(%Document{path: path}), do: Markdown.repo_url(path)

  @doc "Sidebar label for a category key."
  def category_label(key), do: List.keyfind(@categories, key, 0, {key, key}) |> elem(1)

  @doc """
  Documents grouped for the sidebar as `{key, label, documents}`, in category
  order. Development logs come newest first.
  """
  def groups do
    known = Enum.map(@categories, &elem(&1, 0))
    keys = Enum.uniq(known ++ Enum.map(all(), & &1.category))

    for key <- keys, documents = Enum.filter(all(), &(&1.category == key)), documents != [] do
      documents = if key == "devlog", do: Enum.reverse(documents), else: documents
      {key, category_label(key), documents}
    end
  end

  @doc """
  Documents whose title or text contains `query`, ignoring case, as
  `{document, snippet}`. Title matches come first with a nil snippet; body
  matches carry `%{before: _, match: _, after: _}` from the first matching line.
  """
  def search(query) do
    needle = String.downcase(query)

    all()
    |> Enum.flat_map(fn document ->
      cond do
        String.contains?(String.downcase(document.title), needle) -> [{document, nil}]
        snippet = snippet(document.text, needle) -> [{document, snippet}]
        true -> []
      end
    end)
    |> Enum.sort_by(fn {_document, snippet} -> snippet != nil end)
    |> Enum.take(@max_results)
  end

  defp snippet(text, needle) do
    text
    |> String.split("\n")
    |> Enum.find_value(&line_snippet(&1, needle))
  end

  defp line_snippet(line, needle) do
    line = String.replace(line, ~r/^[\s#>*|-]+/u, "")

    case String.split(String.downcase(line), needle, parts: 2) do
      [before, _rest] ->
        at = String.length(before)
        from = max(at - @snippet_before, 0)
        size = String.length(needle)
        rest = String.slice(line, (at + size)..-1//1)
        tail = String.slice(rest, 0, max(@snippet_length - (at - from) - size, 0))

        %{
          before: if(from > 0, do: "...", else: "") <> String.slice(line, from, at - from),
          match: String.slice(line, at, size),
          after: tail <> if(String.length(rest) > String.length(tail), do: "...", else: "")
        }

      [_no_match] ->
        nil
    end
  end
end
