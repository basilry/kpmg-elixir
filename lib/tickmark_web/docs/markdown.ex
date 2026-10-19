defmodule TickmarkWeb.Docs.Markdown do
  @moduledoc """
  Renders project markdown for the docs wiki.

  Raw HTML in the source is dropped (`unsafe: false`) and dangerous URLs such
  as `javascript:` become empty, so the output can go into the page with
  `raw/1`. Relative links are rewritten: a link to another catalogued
  document opens it in the wiki, any other repository file opens on GitHub.
  """

  @repo_blob_url "https://github.com/basilry/kpmg-elixir/blob/main/"

  @options [
    extension: [
      table: true,
      strikethrough: true,
      tasklist: true,
      autolink: true,
      header_id_prefix: ""
    ],
    render: [unsafe: false],
    syntax_highlight: nil
  ]

  @doc "GitHub address of a repository file."
  def repo_url(path), do: @repo_blob_url <> path

  @doc """
  Renders `source`, the file at repository path `path`.

  `doc_ids` maps the repository path of every catalogued document to its
  wiki id. Returns `{html, toc}` where `toc` lists the h2 and h3 headings.
  """
  def render(source, path, doc_ids) do
    dir = Path.dirname(path)

    html =
      source
      |> MDEx.parse_document!(@options)
      |> MDEx.traverse_and_update(fn
        %MDEx.Link{} = link -> %{link | url: rewrite_url(link.url, dir, doc_ids)}
        node -> node
      end)
      |> MDEx.to_html!(@options)
      |> mark_wiki_links()

    {html, toc(html)}
  end

  defp rewrite_url(url, dir, doc_ids) do
    case URI.parse(url) do
      %URI{scheme: nil, host: nil, path: "/" <> _} ->
        url

      %URI{scheme: nil, host: nil, path: path, fragment: fragment}
      when is_binary(path) and path != "" ->
        repo_path = resolve(URI.decode(path), dir)
        suffix = if fragment, do: "#" <> fragment, else: ""

        case Map.fetch(doc_ids, repo_path) do
          {:ok, id} -> wiki_path(id) <> suffix
          :error -> repo_url(repo_path) <> suffix
        end

      _other ->
        url
    end
  end

  # Expanding against a fake root keeps "../" inside the repository.
  defp resolve(path, dir) do
    path
    |> Path.expand("/" <> dir)
    |> String.trim_leading("/")
  end

  defp wiki_path("index"), do: "/docs"
  defp wiki_path(id), do: "/docs/" <> id

  # Wiki links become LiveView patch links, so moving between documents keeps
  # the connection. Raw HTML is dropped, so every anchor here came from a
  # markdown link.
  defp mark_wiki_links(html) do
    String.replace(
      html,
      ~s(<a href="/docs),
      ~s(<a data-phx-link="patch" data-phx-link-state="push" href="/docs)
    )
  end

  # The renderer writes the plain heading text into data-heading-content,
  # so the ids here are exactly the ones in the page.
  defp toc(html) do
    ~r/<h([23]) id="([^"]+)">.*?data-heading-content="([^"]*)"/s
    |> Regex.scan(html)
    |> Enum.map(fn [_, level, id, text] ->
      %{level: String.to_integer(level), id: unescape(id), text: unescape(text)}
    end)
  end

  defp unescape(text) do
    text
    |> String.replace("&quot;", "\"")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end
end
