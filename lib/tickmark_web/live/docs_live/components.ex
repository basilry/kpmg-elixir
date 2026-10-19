defmodule TickmarkWeb.DocsLive.Components do
  @moduledoc "Sidebar, search results, document meta and table of contents for the docs wiki."
  use TickmarkWeb, :html

  alias TickmarkWeb.Docs
  alias TickmarkWeb.Docs.Document

  def doc_path(%Document{id: "index"}), do: ~p"/docs"
  def doc_path(%Document{id: id}), do: ~p"/docs/#{String.split(id, "/")}"

  def file_path(%Document{path: "docs/" <> rest}), do: ~p"/docs/files/#{String.split(rest, "/")}"

  attr :groups, :list, required: true
  attr :current, Document, required: true

  def doc_groups(assigns) do
    ~H"""
    <nav id="docs-groups" aria-label="문서 목록" class="space-y-4">
      <section :for={{key, label, documents} <- @groups} id={"docs-group-#{key}"}>
        <h2 class="mb-1 px-2 text-xs font-semibold text-muted">{label}</h2>
        <ul class="space-y-0.5">
          <li :for={document <- documents}>
            <.doc_link doc={document} current={@current} />
          </li>
        </ul>
      </section>
    </nav>
    """
  end

  attr :results, :list, required: true
  attr :query, :string, required: true
  attr :current, Document, required: true

  def search_results(assigns) do
    ~H"""
    <section id="docs-search-results" aria-live="polite">
      <h2 class="mb-1 px-2 text-xs font-semibold text-muted">검색 결과 {length(@results)}건</h2>
      <p :if={@results == []} id="docs-search-empty" class="px-2 text-muted">
        "{@query}"이(가) 들어간 문서가 없습니다.
      </p>
      <ul class="space-y-0.5">
        <li :for={{document, snippet} <- @results}>
          <.doc_link doc={document} current={@current}>
            <span
              :if={snippet}
              class="mt-0.5 block break-words text-xs font-normal text-muted"
              phx-no-format
            >{snippet.before}<mark class="rounded-sm bg-warning/30 text-base-content">{snippet.match}</mark>{snippet.after}</span>
          </.doc_link>
        </li>
      </ul>
    </section>
    """
  end

  attr :doc, Document, required: true
  attr :current, Document, required: true
  slot :inner_block

  defp doc_link(assigns) do
    ~H"""
    <.link
      patch={doc_path(@doc)}
      aria-current={@doc.id == @current.id && "page"}
      class={[
        "block rounded-field px-2 py-1.5 hover:bg-base-200",
        @doc.id == @current.id && "bg-base-200 font-semibold text-primary"
      ]}
    >
      <span class="line-clamp-2">{@doc.title}</span>
      <span :if={@doc.date} class="block text-xs font-normal text-muted tabular-nums">
        {@doc.date}
      </span>
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :doc, Document, required: true

  def doc_meta(assigns) do
    ~H"""
    <div id="doc-meta" class="mb-4 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted">
      <span class="badge badge-sm badge-ghost">{Docs.category_label(@doc.category)}</span>
      <span :if={@doc.date} class="tabular-nums">{@doc.date}</span>
      <code class="break-all">{@doc.path}</code>
      <a
        href={Docs.github_url(@doc)}
        target="_blank"
        rel="noopener noreferrer"
        class="link link-hover inline-flex items-center gap-1"
      >
        GitHub에서 보기 <.icon name="hero-arrow-top-right-on-square-micro" class="size-3" />
      </a>
    </div>
    """
  end

  attr :toc, :list, required: true

  def doc_toc(assigns) do
    ~H"""
    <nav id="docs-toc" aria-labelledby="docs-toc-title">
      <h2 id="docs-toc-title" class="mb-2 text-xs font-semibold text-muted">이 문서의 목차</h2>
      <ul class="space-y-1 border-l border-base-300 text-xs">
        <li :for={item <- @toc}>
          <a
            href={"#" <> item.id}
            data-toc-link={item.id}
            class={[
              "-ml-px block border-l-2 border-transparent py-0.5 pr-1 hover:text-primary",
              "aria-[current=true]:border-primary aria-[current=true]:font-semibold aria-[current=true]:text-primary",
              if(item.level == 3, do: "pl-6", else: "pl-3")
            ]}
          >
            {item.text}
          </a>
        </li>
      </ul>
    </nav>
    """
  end
end
