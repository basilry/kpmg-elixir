defmodule TickmarkWeb.FindingLive.AiSuggestion do
  @moduledoc "AI suggestions remain separate from human conclusions."
  use TickmarkWeb, :html

  import TickmarkWeb.TestRunLive.Components, only: [system_time: 1]
  import TickmarkWeb.FindingLive.Badges

  attr :triage, :any, required: true
  attr :status, :atom, required: true
  attr :role, :atom, required: true
  attr :below_threshold, :boolean, required: true
  attr :threshold, :integer, required: true

  def ai_suggestion_card(assigns) do
    ~H"""
    <section
      id="ai-triage-card"
      aria-label="AI 제안, 사람의 판단 아님"
      aria-busy={to_string(@status == :queued)}
      class="space-y-3 rounded-box border border-dashed border-accent bg-accent/5 p-4"
    >
      <div class="flex flex-wrap items-center gap-2">
        <h2 class="badge badge-soft badge-accent">
          <.icon name="hero-sparkles" class="size-4" /> AI 제안
        </h2>
        <.risk_badge triage={@triage} status={@status} />
        <span :if={@triage} class="text-xs text-muted"><.system_time at={@triage.inserted_at} /></span>
      </div>
      <p class="text-xs text-accent">이 제안은 판단이 아닙니다. 결론은 작성자가 입력합니다.</p>
      <%= cond do %>
        <% @below_threshold -> %>
          <p id="ai-triage-minor" class="text-muted">점수가 기준({@threshold})보다 낮아 AI 트리아지 대상이 아닙니다.</p>
        <% @status == :queued -> %>
          <div id="ai-triage-pending" role="status" class="space-y-2">
            <p>분석 중</p><div class="skeleton h-3 w-full"></div><div class="skeleton h-3 w-4/5"></div>
          </div>
        <% @status == :failed -> %>
          <p id="ai-triage-failure">AI 제안을 받지 못했습니다. 판단은 AI 제안 없이도 진행할 수 있습니다.</p>
        <% @triage -> %>
          <div id="ai-triage-result" class="space-y-3">
            <div>
              <h3 class="mb-1 text-xs font-semibold text-muted">근거</h3><p class="whitespace-pre-wrap break-words">
                {@triage.rationale}
              </p>
            </div>
            <details>
              <summary class="cursor-pointer text-xs font-semibold text-muted">추가 절차 제안</summary>
              <ol id="ai-procedures" class="mt-2 list-decimal space-y-2 pl-5">
                <li :for={procedure <- @triage.suggested_procedures}>
                  <p class="whitespace-pre-wrap break-words">{procedure["procedure"]}</p>
                  <p class="text-xs text-muted">확보할 증거: {procedure["evidence_to_obtain"]}</p>
                </li>
              </ol>
            </details>
            <div :if={@triage.missing_information != []} id="ai-missing-information">
              <h3 class="text-xs font-semibold text-muted">AI가 판단에 부족하다고 본 정보</h3>
              <ul class="mt-1 list-disc space-y-1 pl-5">
                <li :for={information <- @triage.missing_information}>{information}</li>
              </ul>
            </div>
            <details id="ai-generation-info" class="text-xs">
              <summary class="cursor-pointer text-muted">생성 정보</summary>
              <dl class="mt-2 grid gap-2 rounded-field bg-base-100 p-3">
                <div>
                  <dt class="text-muted">요청 모델 (model)</dt><dd class="font-mono break-all">
                    {@triage.model}
                  </dd>
                </div>
                <div :if={@triage.response_model != @triage.model}>
                  <dt class="text-muted">응답 모델 (response_model)</dt><dd class="font-mono break-all">
                    {@triage.response_model}
                  </dd>
                </div>
                <div>
                  <dt class="text-muted">프롬프트 버전 (prompt_version)</dt><dd class="font-mono">
                    {@triage.prompt_version}
                  </dd>
                </div>
                <div>
                  <dt class="text-muted">입력 해시 (input_hash)</dt><dd class="font-mono">
                    {String.slice(@triage.input_hash, 0, 8)}
                  </dd>
                </div>
                <div>
                  <dt class="text-muted">생성 시각</dt><dd>
                    <.system_time at={@triage.inserted_at} seconds /> KST
                  </dd>
                </div>
              </dl>
            </details>
          </div>
        <% true -> %>
          <p>룰 근거와 전표 사실을 바탕으로 위험도, 추가 절차, 부족한 정보를 제안합니다. 결론은 내리지 않습니다.</p>
      <% end %>
      <div :if={!@below_threshold && @status != :queued} class="space-y-1">
        <button
          id="ai-triage-request"
          type="button"
          phx-click="request_triage"
          phx-disable-with="요청 중"
          disabled={@role != :preparer}
          aria-describedby="ai-triage-request-help"
          class="btn btn-sm btn-accent btn-outline"
        >
          {if @status in [:failed, :succeeded], do: "다시 요청", else: "AI 제안 요청"}
        </button>
        <p id="ai-triage-request-help" class="text-xs text-muted">
          {if @role == :reviewer,
            do: "작성자만 요청할 수 있습니다. 작성자가 요청하면 여기에 보입니다.",
            else: "요청자가 감사 로그에 남습니다."}
        </p>
      </div>
    </section>
    """
  end
end
