defmodule TickmarkWeb.TestRunLive.Show do
  @moduledoc "S4: live rule progress and findings from one test run."
  use TickmarkWeb, :live_view

  import TickmarkWeb.EngagementLive.Components, only: [fiscal_year_label: 1, import_source: 1]
  import TickmarkWeb.TestRunLive.Components

  alias Tickmark.{Engagements, Ledger, Testing}
  alias Tickmark.Testing.TestRun
  alias TickmarkWeb.Format

  @statuses %{
    "open" => :open,
    "concluded" => :concluded,
    "approved" => :approved,
    "rejected" => :rejected
  }

  @impl true
  def mount(%{"id" => id, "run_id" => run_id}, _session, socket) do
    scope = socket.assigns.current_scope
    engagement = Engagements.get_engagement!(scope, id)
    run = Testing.get_test_run!(scope, run_id)
    ensure_same_engagement!(run, engagement.id)
    ledger_import = Ledger.get_import!(scope, run.ledger_import_id)

    started_by =
      Enum.find(Engagements.list_members(scope, engagement), &(&1.user_id == run.started_by_id))

    if connected?(socket) do
      :ok = Engagements.subscribe(scope, engagement.id)
      :ok = Testing.subscribe_test_run(scope, run.id)
    end

    {:ok,
     socket
     |> assign(
       page_title: "테스트 실행",
       engagement: engagement,
       test_run: run,
       ledger_import: ledger_import,
       started_by: if(started_by, do: started_by.user.email, else: "-"),
       tab: "queue",
       filters: %{queue: :review, status: nil, rule_id: nil},
       counts: %{review_queue: 0, minor: 0},
       filter_form: to_form(%{"rule_id" => "", "status" => ""}, as: :filter)
     )
     |> stream_configure(:findings, dom_id: &"s4-finding-#{&1.id}")
     |> stream(:findings, [])}
  end

  @impl true
  def handle_params(%{"id" => id, "run_id" => run_id} = params, _uri, socket) do
    # Query patches belong to this run. Route navigation mounts a fresh view.
    ensure_same_engagement!(socket.assigns.test_run, id)

    if socket.assigns.test_run.id != run_id do
      raise Ecto.NoResultsError, queryable: TestRun
    end

    tab = if params["tab"] in ["minor", "all"], do: params["tab"], else: "queue"
    queue = %{"queue" => :review, "minor" => :minor, "all" => :all}[tab]
    rule_ids = Enum.map(socket.assigns.test_run.test_run_rules, & &1.rule_id)
    rule_id = if params["rule_id"] in rule_ids, do: params["rule_id"]
    status = Map.get(@statuses, params["status"])
    filters = %{queue: queue, rule_id: rule_id, status: status}

    form_params = %{
      "rule_id" => rule_id || "",
      "status" => if(status, do: Atom.to_string(status), else: "")
    }

    {:noreply,
     socket
     |> assign(tab: tab, filters: filters, filter_form: to_form(form_params, as: :filter))
     |> refresh_findings()}
  end

  @impl true
  def handle_event("filter", %{"filter" => params}, socket) do
    query = %{tab: socket.assigns.tab, rule_id: params["rule_id"], status: params["status"]}

    {:noreply,
     push_patch(socket, to: run_path(socket.assigns.engagement, socket.assigns.test_run, query))}
  end

  @impl true
  def handle_info({event, %{test_run_id: id}}, socket)
      when event in [:rule_progress, :run_completed] do
    if id == socket.assigns.test_run.id do
      run = Testing.get_test_run!(socket.assigns.current_scope, id)
      {:noreply, socket |> assign(:test_run, run) |> refresh_findings()}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:finding_updated, _payload}, socket), do: {:noreply, refresh_findings(socket)}
  def handle_info({:import_updated, _payload}, socket), do: {:noreply, socket}
  def handle_info({:test_run_updated, _payload}, socket), do: {:noreply, socket}
  def handle_info({:audit_appended, _payload}, socket), do: {:noreply, socket}

  defp ensure_same_engagement!(%TestRun{engagement_id: id}, id), do: :ok
  defp ensure_same_engagement!(_run, _id), do: raise(Ecto.NoResultsError, queryable: TestRun)

  defp refresh_findings(socket) do
    %{current_scope: scope, test_run: run, filters: filters} = socket.assigns

    findings =
      if run.status == :running, do: [], else: Testing.list_findings(scope, run.id, filters)

    socket
    |> assign(:counts, Testing.count_findings(scope, run.id))
    |> stream(:findings, findings, reset: true)
  end

  defp run_path(engagement, run, query) do
    query = Map.reject(query, fn {_key, value} -> value in [nil, ""] end)
    ~p"/engagements/#{engagement}/runs/#{run}?#{query}"
  end

  defp tab_query(tab, filters), do: %{tab: tab, rule_id: filters.rule_id, status: filters.status}

  defp rule_options(run),
    do: [{"전체 룰", ""} | Enum.map(run.test_run_rules, &{Format.rule_name(&1.rule_id), &1.rule_id})]

  defp status_options do
    [{"전체", ""}, {"미판단", "open"}, {"검토 대기", "concluded"}, {"승인", "approved"}, {"반려", "rejected"}]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="s4" class="space-y-6">
        <header id="s4-main-1" class="space-y-1">
          <nav aria-label="이동 경로" class="text-sm text-muted">
            <.link navigate={~p"/engagements"} class="link link-hover">감사 대상</.link>
            <span aria-hidden="true">/</span>
            <.link navigate={~p"/engagements/#{@engagement}"} class="link link-hover">
              {@engagement.client_name} {fiscal_year_label(@engagement.fiscal_year)}
            </.link>
            <span aria-hidden="true">/</span><span>테스트 실행</span>
          </nav>
          <h1 class="text-xl font-semibold">
            테스트 실행 <.system_time at={@test_run.started_at} /> KST
          </h1>
          <p class="flex flex-wrap gap-x-4 text-xs text-muted">
            <span>{import_source(@ledger_import)}</span>
            <span>기준 점수 {@test_run.triage_threshold}</span><span>실행 {@started_by}</span>
          </p>
        </header>

        <.test_progress run={@test_run} />

        <section
          :if={@tab != "minor"}
          id="s4-main-3"
          aria-label="AI 트리아지"
          class="flex flex-wrap items-center justify-between gap-3 rounded-box border border-dashed border-accent bg-accent/5 p-4"
        >
          <div class="flex items-center gap-2">
            <span class="badge badge-soft badge-accent"><.icon name="hero-sparkles" /> AI 트리아지</span>
            <span id="s4-triage-summary">-<span class="sr-only">없음</span></span>
          </div>
          <button
            id="s4-triage-request"
            type="button"
            class="btn btn-sm"
            disabled
            aria-label="AI 트리아지 요청"
          >
            -<span class="sr-only">없음</span>
          </button>
        </section>

        <div id="s4-main" class="space-y-3">
          <nav id="s4-main-4" class="tabs tabs-border" aria-label="목록 필터">
            <.link
              :for={
                {key, label, count} <- [
                  {"queue", "검토 큐", @counts.review_queue},
                  {"minor", "경미 적중", @counts.minor},
                  {"all", "전체", @counts.review_queue + @counts.minor}
                ]
              }
              id={"s4-tab-#{key}"}
              patch={run_path(@engagement, @test_run, tab_query(key, @filters))}
              class={["tab gap-2", @tab == key && "tab-active"]}
              aria-current={@tab == key && "page"}
            >
              {label} <span class="badge badge-sm tabular-nums">{Format.format_count(count)}</span>
            </.link>
          </nav>
          <.form
            for={@filter_form}
            id="s4-main-5"
            phx-change="filter"
            aria-label="전표 필터"
            class="flex flex-wrap gap-x-3"
          >
            <div class="w-48">
              <.input
                id="s4-rule-filter"
                field={@filter_form[:rule_id]}
                type="select"
                label="적중 룰"
                options={rule_options(@test_run)}
              />
            </div>
            <div class="w-40">
              <.input
                id="s4-status-filter"
                field={@filter_form[:status]}
                type="select"
                label="검토 상태"
                options={status_options()}
              />
            </div>
          </.form>
          <p
            :if={@test_run.status == :running}
            id="s4-running"
            role="status"
            class="rounded-box border border-base-300 bg-base-100 p-6 text-center text-sm text-muted"
          >
            룰이 모두 끝나면 검토 큐가 열립니다.
          </p>
          <.findings_table
            :if={@test_run.status != :running}
            rows={@streams.findings}
            engagement={@engagement}
            show_ai={@tab != "minor"}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
