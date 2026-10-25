defmodule TickmarkWeb.Docs.Loader do
  @moduledoc """
  Reads project documents from disk and builds `TickmarkWeb.Docs.Document`s.

  Only `TickmarkWeb.Docs` calls this, at compile time.
  """

  alias TickmarkWeb.Docs.{Document, Markdown}

  @root_files [
    {"docs/README.md", "index"},
    {"README.md", "readme"},
    {"TASKS.md", "tasks"},
    {"AGENTS.md", "agents"}
  ]
  @file_name ~r/^(\d{4}-\d{2}-\d{2})-(\d+)-/

  @doc "Repository paths of every document, in display order."
  def paths(root) do
    fixed = for {path, _id} <- @root_files, File.regular?(Path.join(root, path)), do: path

    others =
      root
      |> Path.join("docs/**/*.{md,html}")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.reject(&(&1 in fixed))
      |> Enum.sort_by(&sort_key/1)

    fixed ++ others
  end

  @doc "Reads and renders the documents at `paths`."
  def build(root, paths) do
    ids = Map.new(paths, &{&1, id(&1)})
    ensure_unique!(ids)

    Enum.map(paths, fn path ->
      content = File.read!(Path.join(root, path))
      {date, seq} = date_seq(path)

      document = %{
        id: Map.fetch!(ids, path),
        path: path,
        category: category(path),
        date: date,
        seq: seq
      }

      struct!(Document, Map.merge(document, render(path, content, ids)))
    end)
  end

  defp render(path, content, ids) do
    if Path.extname(path) == ".html" do
      %{format: :html, body: content, title: html_title(content, path), text: plain_text(content)}
    else
      {html, toc} = Markdown.render(content, path, ids)
      title = markdown_title(content, path)
      %{format: :markdown, body: html, toc: toc, title: title, text: plain_text(html)}
    end
  end

  defp id(path) do
    case List.keyfind(@root_files, path, 0) do
      {^path, id} -> id
      nil -> path |> Path.relative_to("docs") |> Path.rootname()
    end
  end

  # Ids come from file names, which AGENTS.md 3.2 keeps unique. A clash means
  # that rule was broken, so the build stops and names the files.
  defp ensure_unique!(ids) do
    ids
    |> Enum.group_by(fn {_path, id} -> id end, fn {path, _id} -> path end)
    |> Enum.filter(fn {_id, paths} -> length(paths) > 1 end)
    |> case do
      [] -> :ok
      clashes -> raise ArgumentError, "docs wiki ids clash: #{inspect(clashes)}"
    end
  end

  defp category(path) do
    case Path.split(path) do
      ["docs", folder, _file | _] -> folder
      _root_or_docs_file -> "project"
    end
  end

  defp date_seq(path) do
    case Regex.run(@file_name, Path.basename(path)) do
      [_, date, seq] -> {date, String.to_integer(seq)}
      nil -> {nil, nil}
    end
  end

  defp sort_key(path) do
    {date, seq} = date_seq(path)
    {date || "", seq || 0, path}
  end

  defp markdown_title(content, path) do
    case Regex.run(~r/^#\s+(.+?)\s*#*\s*$/m, content) do
      [_, title] -> title |> String.replace("`", "") |> String.replace("**", "")
      nil -> fallback_title(path)
    end
  end

  defp html_title(content, path) do
    case Regex.run(~r/<title>([^<]+)<\/title>/i, content) do
      [_, title] -> String.trim(title)
      nil -> fallback_title(path)
    end
  end

  defp fallback_title(path) do
    path
    |> Path.basename()
    |> Path.rootname()
    |> String.replace(@file_name, "")
    |> String.replace("-", " ")
  end

  # Visible text of rendered HTML, one block per line, for search.
  defp plain_text(content) do
    content
    |> String.replace(~r/<(script|style)\b.*?<\/\1>/is, " ")
    |> String.replace(~r/<\/(p|div|li|tr|h[1-6]|section|dt|dd)>|<br\s*\/?>/i, "\n")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&amp;", "&")
    |> String.split("\n")
    |> Enum.map(&(&1 |> String.split() |> Enum.join(" ")))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end
end
