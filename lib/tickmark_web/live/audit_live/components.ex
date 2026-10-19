defmodule TickmarkWeb.AuditLive.Components do
  @moduledoc "Audit rows built only from the event snapshot, without looking up its subject."
  use TickmarkWeb, :html

  alias TickmarkWeb.Format

  @action_labels %{
    "engagement.created" => "감사 대상 생성",
    "engagement.member_added" => "멤버 추가",
    "ledger_import.created" => "GL 적재 시작",
    "ledger_import.succeeded" => "GL 적재 완료",
    "ledger_import.failed" => "GL 적재 실패",
    "test_run.started" => "테스트 실행 시작",
    "test_run_rule.failed" => "룰 실행 실패",
    "test_run.completed" => "테스트 실행 완료",
    "ai_triage.requested" => "AI 제안 요청",
    "ai_triage.completed" => "AI 제안 완료",
    "ai_triage.failed" => "AI 제안 실패",
    "conclusion.submitted" => "결론 제출",
    "review.approved" => "승인",
    "review.rejected" => "반려",
    "review.denied" => "검토 거부됨"
  }

  @failure_labels %{
    "validation_failed" => "입력 검증 실패",
    "file_missing" => "파일을 찾을 수 없음",
    "worker_failed" => "파일 처리 실패",
    "rate_limited" => "요청 한도 초과",
    "transient" => "일시적 오류",
    "invalid_output" => "응답 형식 오류",
    "refusal" => "모델 응답 거부",
    "not_configured" => "AI 설정 없음",
    "request_rejected" => "요청 거부",
    "worker_crashed" => "작업 실행 실패"
  }

  attr :id, :string, required: true
  attr :event, :map, required: true
  attr :engagement, :map, required: true
  attr :actor_labels, :map, required: true

  def audit_event_item(assigns) do
    assigns =
      assigns
      |> assign(:summary, summary(assigns.event))
      |> assign(:subject_path, subject_path(assigns.event, assigns.engagement))

    ~H"""
    <li
      id={@id}
      tabindex="-1"
      data-action={@event.action}
      class={[
        "flex min-w-0 gap-3 border-b border-base-300 py-3 text-sm",
        @event.action == "review.denied" && "border-l-4 border-l-warning bg-warning/10 px-3"
      ]}
    >
      <span class={actor_class(@event.actor_type)} aria-hidden="true">
        <.icon name={actor_icon(@event.actor_type)} class="size-4" />
      </span>
      <div class="min-w-0 flex-1 space-y-1">
        <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1 text-xs">
          <span class="font-mono text-muted">#{@event.seq}</span>
          <time
            datetime={DateTime.to_iso8601(@event.inserted_at)}
            title={Format.utc_title(@event.inserted_at)}
            class="tabular-nums text-muted"
          >
            {Format.format_kst(@event.inserted_at, :second)}
          </time>
          <span
            data-column="actor"
            title={@event.actor_id}
            class={["break-all", @event.actor_type != :user && "font-mono"]}
          >
            <span class="sr-only">{actor_type_label(@event.actor_type)}: </span>
            {Map.get(@actor_labels, @event.actor_id, @event.actor_id)}
          </span>
        </div>
        <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
          <span
            data-column="action"
            class={[@event.action == "review.denied" && "font-semibold text-warning"]}
          >
            <.icon :if={@event.action == "review.denied"} name="hero-exclamation-triangle" />
            {action_label(@event.action)}
          </span>
          <code class="break-all text-xs text-muted">{@event.action}</code>
        </div>
        <div class="flex min-w-0 flex-wrap items-baseline gap-x-2 gap-y-1">
          <span class="text-xs text-muted">대상</span>
          <.link
            :if={@subject_path}
            navigate={@subject_path}
            title={@event.subject_id}
            class={[
              "link link-hover text-primary",
              @event.subject_type == "finding" && "whitespace-nowrap font-mono slashed-zero"
            ]}
          >
            {subject_label(@event, @engagement)}
          </.link>
          <span :if={!@subject_path} class="break-all font-mono" title={@event.subject_id}>
            {@event.subject_type}
          </span>
          <p :if={@summary != ""} data-column="summary" class="min-w-0 truncate" title={@summary}>
            {@summary}
          </p>
        </div>
        <details id={"#{@id}-payload"} class="min-w-0 text-xs">
          <summary class="w-fit cursor-pointer py-1 text-muted">payload</summary>
          <pre class="mt-1 max-w-full overflow-x-auto rounded-box bg-base-200 p-3 font-mono"><code>{Jason.encode!(@event.payload, pretty: true)}</code></pre>
        </details>
      </div>
    </li>
    """
  end

  defp action_label(action), do: Map.get(@action_labels, action, action)

  defp actor_class(:user),
    do: "flex size-6 shrink-0 items-center justify-center rounded-full bg-primary/10 text-primary"

  defp actor_class(:agent),
    do: "flex size-6 shrink-0 items-center justify-center rounded-full bg-accent/10 text-accent"

  defp actor_class(:system),
    do: "flex size-6 shrink-0 items-center justify-center rounded-full bg-base-300"

  defp actor_icon(:user), do: "hero-user-circle"
  defp actor_icon(:agent), do: "hero-sparkles"
  defp actor_icon(:system), do: "hero-cog-6-tooth"

  defp actor_type_label(:user), do: "사람"
  defp actor_type_label(:agent), do: "AI"
  defp actor_type_label(:system), do: "시스템"

  defp subject_path(%{subject_type: "finding", subject_id: id}, engagement),
    do: ~p"/engagements/#{engagement}/findings/#{id}"

  defp subject_path(%{subject_type: "test_run", subject_id: id}, engagement),
    do: ~p"/engagements/#{engagement}/runs/#{id}"

  defp subject_path(%{subject_type: "ledger_import", subject_id: id}, engagement),
    do: ~p"/engagements/#{engagement}" <> "#imports-#{id}"

  defp subject_path(%{subject_type: "engagement"}, engagement),
    do: ~p"/engagements/#{engagement}"

  defp subject_path(_event, _engagement), do: nil

  defp subject_label(%{subject_type: "finding", payload: payload}, _engagement),
    do: payload["entry_number"] || "전표"

  defp subject_label(%{subject_type: "test_run"}, _engagement), do: "테스트 실행"

  defp subject_label(%{subject_type: "ledger_import", payload: payload}, _engagement),
    do: payload["original_filename"] || "GL 적재"

  defp subject_label(%{subject_type: "engagement"}, engagement), do: engagement.client_name

  defp summary(%{action: "engagement.created", payload: payload}) do
    if payload["fiscal_year"], do: "FY#{payload["fiscal_year"]}", else: ""
  end

  defp summary(%{action: "engagement.member_added", payload: payload}) do
    case payload["role"] do
      "preparer" -> "작성자 추가"
      "reviewer" -> "검토자 추가"
      _ -> ""
    end
  end

  defp summary(%{action: "ledger_import.created", payload: payload}) do
    if payload["source_kind"] == "generated", do: "합성 GL", else: "CSV 업로드"
  end

  defp summary(%{action: "ledger_import.succeeded", payload: payload}),
    do: "전표 #{count(payload["entry_count"])}건, 라인 #{count(payload["line_count"])}건"

  defp summary(%{action: "ledger_import.failed", payload: payload}),
    do:
      "#{Map.get(@failure_labels, payload["reason"], "적재 실패")}, 오류 #{count(payload["error_count"])}건"

  defp summary(%{action: "test_run.started", payload: payload}) do
    rule_ids = payload["rule_ids"] || []
    "룰 #{length(rule_ids)}개, 기준 점수 #{payload["triage_threshold"] || "-"}"
  end

  defp summary(%{action: "test_run_rule.failed", payload: payload}),
    do: if(payload["rule_id"], do: Format.rule_name(payload["rule_id"]), else: "")

  defp summary(%{action: "test_run.completed", payload: payload}) do
    status = if payload["status"] == "completed_with_errors", do: "일부 실패, ", else: ""
    "#{status}적중 전표 #{count(payload["finding_count"])}건"
  end

  defp summary(%{action: "ai_triage.requested", payload: %{"enqueued" => enqueued}}),
    do: "#{count(enqueued)}건 요청"

  defp summary(%{action: "ai_triage.completed", payload: payload}) do
    risk = %{"high" => "높음", "medium" => "중간", "low" => "낮음"}[payload["risk_level"]] || "-"
    reused = if payload["reused"] == true, do: " (기존 제안 재사용)", else: ""
    "위험도 #{risk}#{reused}"
  end

  defp summary(%{action: "ai_triage.failed", payload: payload}),
    do: Map.get(@failure_labels, payload["reason"], "분석 실패")

  defp summary(%{action: "conclusion.submitted", payload: payload}),
    do:
      %{"no_exception" => "이상 없음", "needs_follow_up" => "추가 확인 필요", "exception" => "예외"}[
        payload["outcome"]
      ] || ""

  defp summary(%{action: "review.rejected", payload: payload}),
    do: payload |> Map.get("comment", "") |> String.split(~r/\R/u, parts: 2) |> hd()

  defp summary(%{action: "review.denied", payload: payload}) do
    case payload["reason"] do
      "role" -> "작성자는 승인, 반려할 수 없습니다 (직무분리)"
      "self_review" -> "본인이 제출한 결론은 승인, 반려할 수 없습니다"
      _ -> "검토 권한 없음"
    end
  end

  defp summary(_event), do: ""

  defp count(value) when is_integer(value), do: Format.format_count(value)
  defp count(_value), do: "-"
end
