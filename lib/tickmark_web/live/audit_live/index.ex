defmodule TickmarkWeb.AuditLive.Index do
  @moduledoc "S6: a read-only, filtered audit trail with explicit refresh and cursor pagination."
  use TickmarkWeb, :live_view

  import TickmarkWeb.AuditLive.Components
  import TickmarkWeb.EngagementLive.Components, only: [fiscal_year_label: 1]

  alias Tickmark.{AuditTrail, Engagements}
  alias Tickmark.Engagements.Engagement
  alias TickmarkWeb.Format

  @page_size 50
  @actor_types %{"user" => :user, "agent" => :agent, "system" => :system}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    engagement = Engagements.get_engagement!(scope, id)

    if connected?(socket), do: :ok = Engagements.subscribe(scope, engagement.id)

    actor_labels =
      Map.new(Engagements.list_members(scope, engagement), &{&1.user_id, &1.user.email})

    {:ok,
     socket
     |> assign(page_title: "감사 로그", engagement: engagement, actor_labels: actor_labels)
     |> stream_configure(:events, dom_id: &"audit-event-#{&1.seq}")
     |> stream(:events, [])}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    if socket.assigns.engagement.id != id,
      do: raise(Ecto.NoResultsError, queryable: Engagement)

    filters = %{
      actor_type: Map.get(@actor_types, params["actor"]),
      entry_number: valid_entry_number(params["subject"]),
      run_id: valid_run_id(params["run"])
    }

    {:noreply,
     socket
     |> assign(
       filters: filters,
       filter_form: to_form(%{"subject" => filters.entry_number || ""}, as: :filter)
     )
     |> refresh_events()}
  end

  @impl true
  def handle_event("filter_actor", %{"actor" => actor}, socket) do
    filters = %{socket.assigns.filters | actor_type: Map.get(@actor_types, actor)}
    {:noreply, push_patch(socket, to: audit_path(socket.assigns.engagement, filters))}
  end

  def handle_event("filter_subject", %{"filter" => params}, socket) do
    filters = %{socket.assigns.filters | entry_number: valid_entry_number(params["subject"])}
    {:noreply, push_patch(socket, to: audit_path(socket.assigns.engagement, filters))}
  end

  def handle_event("refresh", _params, socket) do
    socket = refresh_events(socket)

    socket =
      if socket.assigns.newest_seq > 0 do
        push_event(socket, "audit:focus-first", %{id: "audit-event-#{socket.assigns.newest_seq}"})
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("load_more", _params, %{assigns: %{more?: false}} = socket),
    do: {:noreply, socket}

  def handle_event("load_more", _params, socket) do
    %{current_scope: scope, engagement: engagement, filters: filters, oldest_seq: seq} =
      socket.assigns

    events =
      AuditTrail.list_events(
        scope,
        engagement.id,
        [before_seq: seq, limit: @page_size] ++ event_options(filters)
      )

    {:noreply,
     socket
     |> assign(more?: length(events) == @page_size, oldest_seq: last_seq(events, seq))
     |> stream(:events, events)}
  end

  @impl true
  def handle_info({:audit_appended, %{seq: seq} = event}, socket) do
    if seq > socket.assigns.newest_seq and matches_filters?(event, socket.assigns.filters) do
      pending_seqs = MapSet.put(socket.assigns.pending_seqs, seq)
      {:noreply, assign(socket, pending_seqs: pending_seqs, new_count: MapSet.size(pending_seqs))}
    else
      {:noreply, socket}
    end
  end

  # Every screen shares the engagement topic. These messages do not change
  # the historical rows, so they must not reset the reader's position.
  def handle_info({event, _payload}, socket)
      when event in [
             :import_updated,
             :test_run_updated,
             :finding_updated,
             :triage_requested,
             :member_added,
             :rule_progress,
             :run_completed
           ],
      do: {:noreply, socket}

  defp refresh_events(socket) do
    %{current_scope: scope, engagement: engagement, filters: filters} = socket.assigns
    events = AuditTrail.list_events(scope, engagement.id, event_options(filters))

    socket
    |> assign(
      newest_seq: if(events == [], do: 0, else: hd(events).seq),
      oldest_seq: last_seq(events, nil),
      more?: length(events) == @page_size,
      empty?: events == [],
      pending_seqs: MapSet.new(),
      new_count: 0
    )
    |> stream(:events, events, reset: true)
  end

  defp last_seq([], fallback), do: fallback
  defp last_seq(events, _fallback), do: List.last(events).seq

  defp event_options(filters) do
    [
      actor_type: filters.actor_type,
      entry_number: filters.entry_number,
      subject: if(filters.run_id, do: {"test_run", filters.run_id})
    ]
  end

  defp matches_filters?(event, filters) do
    (is_nil(filters.actor_type) or event.actor_type == filters.actor_type) and
      (is_nil(filters.entry_number) or event.entry_number == filters.entry_number) and
      (is_nil(filters.run_id) or
         (event.subject_type == "test_run" and event.subject_id == filters.run_id))
  end

  # Entry numbers are opaque text, including leading zeros and spaces.
  # Reject blank, control characters and values beyond the CSV cell limit.
  defp valid_entry_number(value) when is_binary(value) do
    if String.valid?(value) and String.trim(value) != "" and
         length(String.codepoints(value)) <= 200 and
         not Regex.match?(~r/[[:cntrl:]]/u, value),
       do: value
  end

  defp valid_entry_number(_value), do: nil

  defp valid_run_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp valid_run_id(_value), do: nil

  defp audit_path(engagement, filters) do
    query = %{
      actor: filters.actor_type,
      subject: filters.entry_number,
      run: filters.run_id
    }

    query = Map.reject(query, fn {_key, value} -> is_nil(value) end)

    if query == %{},
      do: ~p"/engagements/#{engagement}/audit",
      else: ~p"/engagements/#{engagement}/audit?#{query}"
  end

  defp filtered?(filters), do: Enum.any?(Map.values(filters), &(not is_nil(&1)))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      engagement={@engagement}
      active={:audit}
    >
      <div id="s6" class="min-w-0 space-y-6">
        <header class="space-y-1">
          <nav aria-label="이동 경로" class="text-sm text-muted">
            <.link navigate={~p"/engagements"} class="link link-hover">감사 대상</.link>
            <span aria-hidden="true">/</span>
            <.link navigate={~p"/engagements/#{@engagement}"} class="link link-hover">
              {@engagement.client_name} {fiscal_year_label(@engagement.fiscal_year)}
            </.link>
            <span aria-hidden="true">/</span><span aria-current="page">감사 로그</span>
          </nav>
          <h1 class="text-xl font-semibold">감사 로그</h1>
          <p class="text-sm text-muted">읽기 전용. 기록은 수정하거나 삭제할 수 없습니다.</p>
        </header>

        <section aria-label="감사 로그 필터" class="flex flex-wrap items-end gap-3">
          <div role="group" aria-label="행위자 유형" class="flex flex-wrap gap-1 pb-2">
            <button
              :for={{type, label} <- [{nil, "전체"}, {:user, "사람"}, {:agent, "AI"}, {:system, "시스템"}]}
              id={"actor-filter-#{type || "all"}"}
              type="button"
              phx-click="filter_actor"
              phx-value-actor={type || ""}
              aria-pressed={to_string(@filters.actor_type == type)}
              class={[
                "btn btn-sm",
                if(@filters.actor_type == type, do: "btn-primary", else: "btn-ghost")
              ]}
            >
              {label}
            </button>
          </div>
          <.form
            for={@filter_form}
            id="subject-filter-form"
            phx-submit="filter_subject"
            class="flex min-w-0 flex-wrap items-end gap-2"
          >
            <div class="w-56 max-w-full">
              <.input
                id="subject-filter"
                field={@filter_form[:subject]}
                label="대상 전표번호"
                placeholder="JE-000123"
                maxlength="200"
              />
            </div>
            <button id="apply-subject-filter" type="submit" class="btn btn-sm mb-2">적용</button>
          </.form>
          <.link
            :if={@filters.run_id}
            id="clear-run-filter"
            patch={audit_path(@engagement, %{@filters | run_id: nil})}
            class="btn btn-sm btn-ghost mb-2"
          >
            실행 필터 해제
          </.link>
        </section>

        <div id="new-events-status" aria-live="polite" aria-atomic="true">
          <button
            :if={@new_count > 0}
            id="new-events"
            type="button"
            phx-click="refresh"
            class="btn btn-sm btn-soft"
          >
            <.icon name="hero-arrow-path" /> 새 이벤트 {Format.format_count(@new_count)}건
          </button>
        </div>

        <section id="audit-focus" phx-hook=".AuditFocus" aria-label="감사 이벤트" class="min-w-0">
          <p class="mb-2 text-xs text-muted">시각 (KST)</p>
          <div
            :if={@empty?}
            id="audit-events-empty"
            class="rounded-box border border-base-300 bg-base-100 p-6 text-center text-sm text-muted"
          >
            <p>{if filtered?(@filters), do: "조건에 맞는 이벤트가 없습니다.", else: "아직 감사 기록이 없습니다."}</p>
            <.link
              :if={filtered?(@filters)}
              id="reset-filters"
              patch={~p"/engagements/#{@engagement}/audit"}
              class="btn btn-sm mt-3"
            >
              필터 초기화
            </.link>
          </div>
          <ol id="audit-events" phx-update="stream" class="min-w-0 border-t border-base-300">
            <.audit_event_item
              :for={{dom_id, event} <- @streams.events}
              id={dom_id}
              event={event}
              engagement={@engagement}
              actor_labels={@actor_labels}
            />
          </ol>
          <div class="mt-4 text-center">
            <button
              :if={@more?}
              id="load-more"
              type="button"
              phx-click="load_more"
              phx-disable-with="불러오는 중"
              class="btn btn-sm"
            >
              더 보기
            </button>
            <p :if={!@more?} id="audit-events-end" class="text-sm text-muted">
              처음 기록까지 모두 보았습니다.
            </p>
          </div>
        </section>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".AuditFocus">
          export default {
            mounted() {
              this.handleEvent("audit:focus-first", ({id}) => {
                this.el.querySelector(`#${id}`)?.focus()
              })
            }
          }
        </script>
      </div>
    </Layouts.app>
    """
  end
end
