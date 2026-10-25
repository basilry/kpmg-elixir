defmodule TickmarkWeb.DocsLive do
  @moduledoc """
  Docs wiki: every project document on one page, with a sidebar grouped by
  category, search over titles and text, and a table of contents.

  Moving between documents is a live patch (`handle_params/3`), so the
  sidebar and search stay as they are.
  """
  use TickmarkWeb, :live_view

  import TickmarkWeb.DocsLive.Components

  alias TickmarkWeb.Docs
  alias TickmarkWeb.Docs.NotFoundError

  @max_query 100

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       groups: Docs.groups(),
       query: "",
       results: [],
       nav_open: false,
       search_form: to_form(%{"q" => ""}, as: :search)
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    doc = fetch_doc!(params)
    {:noreply, assign(socket, doc: doc, page_title: doc.title, nav_open: false)}
  end

  @impl true
  def handle_event("search", %{"search" => %{"q" => q}}, socket) when is_binary(q) do
    query = q |> String.trim() |> String.slice(0, @max_query)
    results = if query == "", do: [], else: Docs.search(query)

    {:noreply,
     assign(socket,
       query: query,
       results: results,
       search_form: to_form(%{"q" => q}, as: :search)
     )}
  end

  def handle_event("toggle_nav", _params, socket) do
    {:noreply, update(socket, :nav_open, &(!&1))}
  end

  defp fetch_doc!(%{"id" => segments}) when is_list(segments) do
    Docs.get(Enum.join(segments, "/")) || raise NotFoundError
  end

  defp fetch_doc!(_params), do: Docs.get("index") || raise(NotFoundError)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:docs}>
      <div
        id="docs-page"
        phx-hook=".DocScroll"
        data-doc-id={@doc.id}
        class={[
          "grid gap-6 text-sm lg:grid-cols-[15rem_minmax(0,1fr)] xl:gap-8",
          @doc.toc != [] && "xl:grid-cols-[15rem_minmax(0,1fr)_13rem]"
        ]}
      >
        <aside
          id="docs-sidebar"
          class="min-w-0 lg:sticky lg:top-18 lg:max-h-[calc(100vh-6rem)] lg:self-start lg:overflow-y-auto lg:pr-1"
        >
          <button
            id="docs-nav-toggle"
            type="button"
            phx-click="toggle_nav"
            aria-expanded={to_string(@nav_open)}
            aria-controls="docs-nav"
            class="btn btn-sm btn-block justify-between lg:hidden"
          >
            문서 목록
            <.icon
              name={if @nav_open, do: "hero-chevron-up-mini", else: "hero-chevron-down-mini"}
              class="size-4"
            />
          </button>
          <div id="docs-nav" class={["mt-3 space-y-4 lg:mt-0 lg:block", !@nav_open && "hidden"]}>
            <.form
              for={@search_form}
              id="docs-search"
              role="search"
              phx-change="search"
              phx-submit="search"
            >
              <.input
                field={@search_form[:q]}
                type="search"
                placeholder="제목, 본문 검색"
                aria-label="문서 검색"
                maxlength="100"
                autocomplete="off"
                phx-debounce="200"
              />
            </.form>
            <.search_results :if={@query != ""} results={@results} query={@query} current={@doc} />
            <.doc_groups :if={@query == ""} groups={@groups} current={@doc} />
          </div>
        </aside>

        <article id="doc-article" class={["min-w-0", @doc.format == :markdown && "max-w-4xl"]}>
          <.doc_meta doc={@doc} />
          <div :if={@doc.format == :html} id="doc-frame-wrap" class="space-y-3">
            <div class="flex flex-wrap items-baseline justify-between gap-2">
              <h1 class="text-xl font-semibold">{@doc.title}</h1>
              <a href={file_path(@doc)} target="_blank" rel="noopener" class="link link-hover text-xs">
                새 탭에서 열기
              </a>
            </div>
            <iframe
              id="doc-frame"
              src={file_path(@doc)}
              title={@doc.title}
              sandbox="allow-scripts"
              class="h-[calc(100vh-12rem)] min-h-[32rem] w-full rounded-box border border-base-300 bg-base-100"
            ></iframe>
          </div>
          <div :if={@doc.format == :markdown} id="doc-body" class="doc-prose">
            {raw(@doc.body)}
          </div>
        </article>

        <aside
          :if={@doc.toc != []}
          id="docs-toc-panel"
          class="hidden xl:sticky xl:top-18 xl:block xl:max-h-[calc(100vh-6rem)] xl:self-start xl:overflow-y-auto"
        >
          <.doc_toc toc={@doc.toc} />
        </aside>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".DocScroll">
        // A live patch keeps the scroll position. When the document changes,
        // go to the linked heading, or to the top. LiveView looks up the raw
        // hash, which misses percent-encoded Korean ids, so decode it here.
        // Also marks the table of contents entry for the heading in view.
        export default {
          mounted() {
            this.docId = this.el.dataset.docId
            this.watchHeadings()
          },
          updated() {
            if (this.el.dataset.docId !== this.docId) {
              this.docId = this.el.dataset.docId
              requestAnimationFrame(() => {
                const target = this.hashTarget()
                if (target) target.scrollIntoView()
                else window.scrollTo(0, 0)
              })
            }
            this.watchHeadings()
          },
          destroyed() {
            if (this.observer) this.observer.disconnect()
          },
          hashTarget() {
            const hash = window.location.hash.slice(1)
            if (hash === "") return null
            try {
              return document.getElementById(decodeURIComponent(hash))
            } catch (_error) {
              return document.getElementById(hash)
            }
          },
          watchHeadings() {
            if (this.observer) this.observer.disconnect()
            const links = new Map()
            this.el.querySelectorAll("[data-toc-link]").forEach(link => links.set(link.dataset.tocLink, link))
            if (links.size === 0 || !("IntersectionObserver" in window)) return

            this.observer = new IntersectionObserver(entries => {
              const visible = entries.find(entry => entry.isIntersecting)
              if (!visible) return
              links.forEach(link => link.removeAttribute("aria-current"))
              const active = links.get(visible.target.id)
              if (active) active.setAttribute("aria-current", "true")
            }, {rootMargin: "-64px 0px -70% 0px"})

            links.forEach((_link, id) => {
              const heading = document.getElementById(id)
              if (heading) this.observer.observe(heading)
            })
          }
        }
      </script>
    </Layouts.app>
    """
  end
end
