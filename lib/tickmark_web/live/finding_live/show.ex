defmodule TickmarkWeb.FindingLive.Show do
  @moduledoc "S5: entry facts, rule evidence, AI suggestions and human review history."
  use TickmarkWeb, :live_view

  import TickmarkWeb.EngagementLive.Components, only: [fiscal_year_label: 1]
  import TickmarkWeb.TestRunLive.Components, only: [system_time: 1]
  import TickmarkWeb.FindingLive.Badges
  import TickmarkWeb.FindingLive.EntryPanels
  import TickmarkWeb.FindingLive.RuleEvidence
  import TickmarkWeb.FindingLive.AiSuggestion
  import TickmarkWeb.FindingLive.ConclusionPanel
  import TickmarkWeb.FindingLive.History
  import TickmarkWeb.FindingLive.SignBar

  alias Tickmark.{Engagements, Testing}
  alias TickmarkWeb.FindingLive.{Actions, State}
  alias Tickmark.Testing.Finding

  @impl true
  def mount(%{"id" => id, "finding_id" => finding_id}, _session, socket) do
    scope = socket.assigns.current_scope
    finding = Testing.get_finding!(scope, finding_id)
    engagement = Engagements.get_engagement!(scope, id)
    ensure_same_engagement!(finding, engagement.id)
    {:ok, role} = Engagements.fetch_role(scope, engagement.id)

    if connected?(socket), do: :ok = Engagements.subscribe(scope, engagement.id)

    {:ok,
     socket
     |> assign(
       page_title: "전표 검토",
       engagement: engagement,
       role: role,
       form: Actions.new_conclusion_form(),
       decision_mode: :idle,
       rejection_form: Actions.new_rejection_form(),
       rejection_length: 0,
       comment_length: 0,
       conclusion_notice: nil
     )
     |> stream_configure(:entry_lines, dom_id: &"entry-line-#{&1.id}")
     |> stream_configure(:rule_hits, dom_id: &"rule-hit-#{&1.id}")
     |> State.refresh_finding(finding)}
  end

  @impl true
  def handle_event("validate", %{"conclusion" => params}, socket) do
    {:noreply, Actions.validate_conclusion(socket, params)}
  end

  def handle_event("submit", %{"conclusion" => params}, socket) do
    {:noreply, Actions.submit(socket, params)}
  end

  def handle_event("start_approve", _params, socket) do
    {:noreply, Actions.start_decision(socket, :approve)}
  end

  def handle_event("start_reject", _params, socket) do
    {:noreply, Actions.start_decision(socket, :reject)}
  end

  def handle_event("cancel_decision", _params, socket) do
    {:noreply, Actions.cancel_decision(socket)}
  end

  def handle_event("validate_rejection", %{"review_decision" => params}, socket) do
    {:noreply, Actions.validate_rejection(socket, params)}
  end

  def handle_event("confirm_approve", params, socket) do
    {:noreply, Actions.decide(socket, params["conclusion-id"], %{"decision" => "approved"})}
  end

  def handle_event("confirm_reject", %{"review_decision" => params} = event, socket) do
    attrs = %{"decision" => "rejected", "comment" => params["comment"]}
    {:noreply, Actions.decide(socket, event["conclusion-id"], attrs)}
  end

  def handle_event("request_triage", _params, socket) do
    {:noreply, Actions.request_triage(socket)}
  end

  @impl true
  def handle_info({:finding_updated, %{finding_id: id}}, socket) do
    if id == socket.assigns.finding.id do
      finding = Testing.get_finding!(socket.assigns.current_scope, id)
      {:noreply, socket |> notify_new_conclusion(finding) |> State.refresh_finding(finding)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({event, _payload}, socket)
      when event in [
             :audit_appended,
             :triage_requested,
             :test_run_updated,
             :import_updated,
             :member_added,
             :rule_progress,
             :run_completed
           ],
      do: {:noreply, socket}

  defp ensure_same_engagement!(%Finding{engagement_id: id}, id), do: :ok
  defp ensure_same_engagement!(_finding, _id), do: raise(Ecto.NoResultsError, queryable: Finding)

  defp notify_new_conclusion(socket, finding) do
    socket =
      if socket.assigns.role == :reviewer,
        do: Actions.cancel_decision(socket),
        else: socket

    previous = socket.assigns.latest_conclusion
    latest = List.last(finding.conclusions)

    if finding.status == :approved do
      assign(socket, :conclusion_notice, nil)
    else
      notify_latest_conclusion(socket, previous, latest)
    end
  end

  defp notify_latest_conclusion(socket, previous, latest) do
    if latest && (is_nil(previous) || latest.id != previous.id) do
      message =
        if socket.assigns.role == :reviewer do
          "작성자가 결론을 다시 제출했습니다. 최신 결론을 확인한 뒤 결정하세요."
        else
          "#{latest.preparer.email}님이 방금 결론을 제출했습니다. 제출하면 새 결론으로 남습니다."
        end

      assign(socket, :conclusion_notice, message)
    else
      socket
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} engagement={@engagement}>
      <div id="s5" class="min-w-0 space-y-5 pb-6 text-sm">
        <header id="finding-header" class="space-y-3">
          <nav
            id="finding-breadcrumb"
            aria-label="이동 경로"
            class="flex flex-wrap items-center gap-1 text-xs text-muted"
          >
            <.link navigate={~p"/engagements"} class="link link-hover">감사 대상</.link>
            <span aria-hidden="true">/</span>
            <.link navigate={~p"/engagements/#{@engagement}"} class="link link-hover">
              {@engagement.client_name} {fiscal_year_label(@engagement.fiscal_year)}
            </.link>
            <span aria-hidden="true">/</span>
            <.link
              navigate={~p"/engagements/#{@engagement}/runs/#{@finding.test_run_id}"}
              class="link link-hover"
            >
              테스트 실행 <.system_time at={@finding.test_run.started_at} />
            </.link>
            <span aria-hidden="true">/</span><span aria-current="page" class="font-mono">{@entry.entry_number}</span>
          </nav>
          <div class="flex flex-wrap items-center gap-3">
            <h1 class="font-mono text-xl font-semibold">{@entry.entry_number}</h1>
            <.score_meter score={@finding.score} />
            <span id="finding-ai-status"><.risk_badge
              triage={@triage}
              status={@finding.triage_status}
            /></span>
            <span id="finding-conclusion-status"><.conclusion_badge outcome={
              @latest_conclusion && @latest_conclusion.outcome
            } /></span>
            <span id="finding-review-status"><.review_badge status={@finding.status} /></span>
          </div>
        </header>

        <.entry_facts entry={@entry} description={@entry_description} />
        <.entry_lines
          rows={@streams.entry_lines}
          number={@entry.entry_number}
          total_debit={@total_debit}
          total_credit={@total_credit}
          balanced={@balanced}
        />
        <.rule_hits rows={@streams.rule_hits} formula={@score_formula} />
        <.ai_suggestion_card
          triage={@triage}
          status={@finding.triage_status}
          role={@role}
          below_threshold={@finding.score < @finding.test_run.triage_threshold}
          threshold={@finding.test_run.triage_threshold}
        />

        <p
          :if={@conclusion_notice}
          id="conclusion-notice"
          role="status"
          class="rounded-box border border-warning bg-warning/10 p-3"
        >
          <.icon name="hero-exclamation-triangle" class="size-4" /> {@conclusion_notice}
        </p>
        <.conclusion_panel
          form={@form}
          mode={@form_mode}
          latest={@latest_conclusion}
          last_decision={@last_decision}
          status={@finding.status}
          comment_length={@comment_length}
        />
        <.finding_history rows={@streams.history} empty?={@history_empty?} />
        <.sign_bar
          status={@finding.status}
          role={@role}
          latest={@latest_conclusion}
          last_decision={@last_decision}
          can_decide={@can_decide}
          current_user_id={@current_scope.user.id}
          decision_mode={@decision_mode}
          rejection_form={@rejection_form}
          rejection_length={@rejection_length}
        />
      </div>
    </Layouts.app>
    """
  end
end
