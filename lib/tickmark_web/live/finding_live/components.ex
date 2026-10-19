defmodule TickmarkWeb.FindingLive.Components do
  @moduledoc "Read-only review panels for S5. AI suggestions and human decisions stay distinct."
  use TickmarkWeb, :html

  import TickmarkWeb.TestRunLive.Components, only: [system_time: 1]
  alias TickmarkWeb.Format

  attr :score, :integer, required: true

  def score_meter(assigns) do
    ~H"""
    <span
      class="inline-flex items-center gap-1.5 whitespace-nowrap"
      aria-label={"점수 #{@score}, #{Format.score_band(@score)}"}
    >
      <b class="tabular-nums">{@score}</b>
      <span class="inline-flex gap-0.5" aria-hidden="true">
        <span
          :for={cell <- 1..5}
          class={[
            "h-2.5 w-1.5 rounded-xs",
            if(cell <= div(@score + 19, 20), do: "bg-base-content", else: "bg-base-300")
          ]}
        ></span>
      </span>
      <span class="text-xs text-muted">{Format.score_band(@score)}</span>
    </span>
    """
  end

  attr :outcome, :atom, required: true

  def conclusion_badge(assigns) do
    {label, color, icon} = conclusion_style(assigns.outcome)
    assigns = assign(assigns, label: label, color: color, icon: icon)

    ~H"""
    <span class={["badge badge-sm whitespace-nowrap", @color]}>
      <.icon name={@icon} class="size-3.5" /> {@label}
    </span>
    """
  end

  attr :status, :atom, required: true

  def review_badge(assigns) do
    ~H"""
    <span :if={@status == :open} class="text-muted">-<span class="sr-only">검토 전</span></span>
    <span :if={@status != :open} class={["badge badge-sm whitespace-nowrap", review_color(@status)]}>
      <.icon name={review_icon(@status)} class="size-3.5" /> {Format.review_status_label(@status)}
    </span>
    """
  end

  attr :triage, :any, required: true
  attr :status, :atom, required: true

  def risk_badge(assigns) do
    ~H"""
    <%= cond do %>
      <% @status == :queued -> %>
        <span class="inline-flex items-center gap-1.5 text-accent"><span
          class="loading loading-dots loading-xs"
          aria-hidden="true"
        ></span>분석 중</span>
      <% @status == :failed -> %>
        <span class="badge badge-sm badge-ghost text-error"><.icon
          name="hero-exclamation-circle"
          class="size-3.5"
        /> AI 실패</span>
      <% @triage -> %>
        <span class={["badge badge-sm badge-soft", risk_color(@triage.risk_level)]}>
          <.icon name={risk_icon(@triage.risk_level)} class="size-3.5" /> {risk_label(
            @triage.risk_level
          )}
        </span>
      <% true -> %>
        <span class="text-muted">-<span class="sr-only">미요청</span></span>
    <% end %>
    """
  end

  attr :entry, :any, required: true
  attr :description, :string, default: nil

  def entry_facts(assigns) do
    ~H"""
    <section
      id="entry-facts"
      aria-labelledby="entry-facts-title"
      class="space-y-3 rounded-box border border-base-300 bg-base-100 p-4"
    >
      <h2 id="entry-facts-title" class="font-semibold">전표 사실</h2>
      <dl class="grid grid-cols-2 gap-x-6 gap-y-3 sm:grid-cols-3">
        <div>
          <dt class="text-xs text-muted">전기일</dt><dd class="tabular-nums">
            {Format.format_date(@entry.posting_date)}
          </dd>
        </div>
        <div>
          <dt class="text-xs text-muted">증빙일</dt><dd class="tabular-nums">
            {Format.format_date(@entry.document_date)}
          </dd>
        </div>
        <div>
          <dt class="text-xs text-muted">입력 일시 (KST)</dt><dd class="tabular-nums">
            {Format.format_kst(@entry.entered_at, :second)}
          </dd>
        </div>
        <div>
          <dt class="text-xs text-muted">회계기간</dt><dd>
            {if @entry.fiscal_period == 13, do: "13(결산조정)", else: @entry.fiscal_period}
          </dd>
        </div>
        <div>
          <dt class="text-xs text-muted">입력자</dt><dd class="font-mono break-all">
            {@entry.entered_by}
          </dd>
        </div>
        <div>
          <dt class="text-xs text-muted">승인자</dt>
          <dd class="flex flex-wrap items-center gap-1">
            <span class="font-mono break-all"><.optional_value value={@entry.approved_by} /></span>
            <span
              :if={@entry.approved_by && @entry.approved_by == @entry.entered_by}
              id="entry-self-approved"
              class="inline-flex items-center text-warning"
            >
              <.icon name="hero-exclamation-triangle" class="size-4" /><span class="sr-only">입력자와 같음</span>
            </span>
          </dd>
        </div>
        <div>
          <dt class="text-xs text-muted">구분</dt><dd>
            {if @entry.source == :manual, do: "수기", else: "자동"}
          </dd>
        </div>
        <div>
          <dt class="text-xs text-muted">거래처</dt><dd
            id="entry-counterparty"
            class="whitespace-pre-wrap break-words"
          >
            <.optional_value value={@entry.counterparty} />
          </dd>
        </div>
        <div class="col-span-full">
          <dt class="text-xs text-muted">적요</dt><dd
            id="entry-description"
            class="whitespace-pre-wrap break-words"
          >
            <.optional_value value={@description} />
          </dd>
        </div>
      </dl>
    </section>
    """
  end

  attr :rows, :any, required: true
  attr :number, :string, required: true
  attr :total_debit, :any, required: true
  attr :total_credit, :any, required: true
  attr :balanced, :boolean, required: true

  def entry_lines(assigns) do
    ~H"""
    <section aria-labelledby="entry-lines-title" class="space-y-2">
      <h2 id="entry-lines-title" class="font-semibold">전표 행</h2>
      <div class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
        <table id="entry-lines" class="table tk-table">
          <caption class="sr-only">{@number} 전표 행</caption>
          <thead>
            <tr>
              <th scope="col" class="hidden sm:table-cell">행</th><th scope="col">계정</th>
              <th scope="col" class="hidden sm:table-cell">적요</th>
              <th scope="col" class="text-right">차변(원)</th><th scope="col" class="text-right">
                대변(원)
              </th>
            </tr>
          </thead>
          <tbody id="entry-line-rows" phx-update="stream">
            <tr :for={{id, line} <- @rows} id={id}>
              <td class="hidden font-mono sm:table-cell">L{line.line_number}</td>
              <td><span class="font-mono">{line.account_code}</span> {line.account_name}</td>
              <td class="hidden whitespace-pre-wrap break-words sm:table-cell">
                <.optional_value value={line.description} />
              </td>
              <td class="text-right tabular-nums whitespace-nowrap"><.money value={line.debit} /></td>
              <td class="text-right tabular-nums whitespace-nowrap">
                <.money value={line.credit} />
              </td>
            </tr>
          </tbody>
          <tfoot>
            <tr id="entry-lines-total">
              <th scope="row">
                <span class="sr-only">합계, </span><span class={[
                  @balanced && "text-success",
                  !@balanced && "text-error"
                ]}>
                  <.icon
                    name={if @balanced, do: "hero-check-circle", else: "hero-exclamation-circle"}
                    class="size-4"
                  />
                  {if @balanced, do: "차대 일치", else: "차대 불일치"}
                </span>
              </th>
              <td class="hidden sm:table-cell"></td><td class="hidden sm:table-cell"></td>
              <td class="text-right tabular-nums"><.money value={@total_debit} /></td>
              <td class="text-right tabular-nums"><.money value={@total_credit} /></td>
            </tr>
          </tfoot>
        </table>
      </div>
    </section>
    """
  end

  attr :rows, :any, required: true
  attr :formula, :string, required: true

  def rule_hits(assigns) do
    ~H"""
    <section
      id="rule-hits"
      aria-labelledby="rule-hits-title"
      class="space-y-3 rounded-box border border-base-300 bg-base-100 p-4"
    >
      <h2 id="rule-hits-title" class="font-semibold">룰 적중</h2>
      <ul id="rule-hit-rows" phx-update="stream" class="divide-y divide-base-300">
        <li :for={{id, hit} <- @rows} id={id} class="space-y-2 py-3 first:pt-0">
          <div class="flex flex-wrap items-baseline gap-x-2">
            <span class="font-semibold tabular-nums">+{hit.score}</span>
            <h3 class="font-medium">{Format.rule_name(hit.rule_id)}</h3>
            <span class="font-mono text-xs text-muted">{hit.rule_id}</span>
          </div>
          <p class="whitespace-pre-wrap break-words">{hit.reason}</p>
          <details class="text-xs">
            <summary class="cursor-pointer text-muted">근거 값</summary>
            <dl class="mt-2 grid gap-2 rounded-field bg-base-200 p-3">
              <div :for={{key, value} <- Enum.sort(hit.details)} class="grid gap-1 sm:grid-cols-2">
                <dt class="font-mono break-all">{key}</dt><dd class="whitespace-pre-wrap break-words">
                  {detail_value(value)}
                </dd>
              </div>
            </dl>
          </details>
        </li>
      </ul>
      <p id="finding-score-formula" class="border-t border-base-300 pt-3 tabular-nums">{@formula}</p>
    </section>
    """
  end

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
          disabled
          aria-describedby="ai-triage-request-help"
          class="btn btn-sm"
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

  attr :form, Phoenix.HTML.Form, required: true
  attr :mode, :atom, required: true
  attr :latest, :any, required: true
  attr :last_decision, :any, required: true
  attr :status, :atom, required: true
  attr :comment_length, :integer, required: true

  def conclusion_panel(assigns) do
    ~H"""
    <section
      id="conclusion-panel"
      data-mode={@mode}
      aria-labelledby="conclusion-title"
      class="space-y-3 rounded-box border border-line-strong bg-base-100 p-4"
    >
      <h2 id="conclusion-title" class="font-semibold">작성자 판단</h2>
      <div
        :if={@status == :rejected && @last_decision}
        id="conclusion-rejection"
        class="space-y-1 border-l-2 border-error bg-error/5 p-3"
      >
        <p class="text-xs font-semibold text-error">
          반려 사유, {@last_decision.reviewer.email}, <.system_time at={@last_decision.inserted_at} />
        </p>
        <p class="whitespace-pre-wrap break-words">{@last_decision.comment}</p>
      </div>
      <%= if @mode == :edit do %>
        <.form
          for={@form}
          id="conclusion-form"
          phx-change="validate"
          phx-submit="validate"
          class="space-y-3"
        >
          <.input
            field={@form[:ai_triage_id]}
            id="conclusion-ai-triage-id"
            type="hidden"
            value={@form[:ai_triage_id].value || ""}
          />
          <fieldset aria-describedby="conclusion-outcome-errors">
            <legend class="mb-2 text-xs font-medium">판단</legend>
            <div class="flex flex-wrap gap-3">
              <label
                :for={
                  {value, outcome} <- [
                    {"no_exception", :no_exception},
                    {"needs_follow_up", :needs_follow_up},
                    {"exception", :exception}
                  ]
                }
                class="inline-flex cursor-pointer items-center gap-1.5"
              >
                <input
                  id={"conclusion-outcome-#{value}"}
                  type="radio"
                  name={@form[:outcome].name}
                  value={value}
                  checked={to_string(@form[:outcome].value) == value}
                  class="radio radio-sm radio-primary"
                />
                <.conclusion_badge outcome={outcome} />
              </label>
            </div>
            <div id="conclusion-outcome-errors" class="mt-1 text-xs text-error">
              <p :for={{message, _opts} <- @form[:outcome].errors}>{message}</p>
            </div>
          </fieldset>
          <.input
            field={@form[:comment]}
            id="conclusion-comment"
            type="textarea"
            label="코멘트 (필수)"
            rows="4"
            placeholder="수행한 절차와 판단 근거"
            aria-describedby="conclusion-comment-help conclusion-character-count"
          />
          <div class="flex flex-wrap justify-between gap-2 text-xs text-muted">
            <p id="conclusion-comment-help">AI 제안을 본 상태로 제출하면 그 제안이 결론에 연결됩니다.</p>
            <span id="conclusion-character-count" class="tabular-nums">{@comment_length} / 2000</span>
          </div>
          <button id="conclusion-submit" type="submit" disabled class="btn btn-primary btn-sm">결론 제출</button>
        </.form>
      <% else %>
        <div id="conclusion-summary" class="space-y-2">
          <%= if @latest do %>
            <.conclusion_badge outcome={@latest.outcome} />
            <p class="whitespace-pre-wrap break-words">{@latest.comment}</p>
            <p class="text-xs text-muted">
              {@latest.preparer.email}, <.system_time at={@latest.inserted_at} />
            </p>
          <% else %>
            <p class="text-muted">아직 결론이 없습니다.</p>
          <% end %>
          <p :if={@mode == :locked} id="conclusion-locked" class="text-xs text-muted">
            <.icon name="hero-lock-closed" class="size-4" /> 승인된 항목은 수정할 수 없습니다
          </p>
        </div>
      <% end %>
    </section>
    """
  end

  attr :rows, :any, required: true
  attr :empty?, :boolean, required: true

  def finding_history(assigns) do
    ~H"""
    <section
      id="history"
      aria-labelledby="history-title"
      class="space-y-3 rounded-box border border-base-300 bg-base-100 p-4"
    >
      <h2 id="history-title" class="font-semibold">이력</h2>
      <p :if={@empty?} id="history-empty" class="text-muted">아직 결론이 없습니다.</p>
      <ol id="history-entries" phx-update="stream" class="divide-y divide-base-300">
        <li :for={{id, entry} <- @rows} id={id} data-kind={entry.kind} class="space-y-1 py-3">
          <div class="flex flex-wrap items-center gap-2">
            <.icon name="hero-user-circle" class="size-4 text-primary" /><span class="font-medium break-all">{entry.actor}</span>
            <span class="text-xs text-muted">{if entry.kind == :conclusion, do: "결론 제출", else: "검토"}</span>
            <.conclusion_badge :if={entry.kind == :conclusion} outcome={entry.outcome} />
            <.review_badge :if={entry.kind == :decision} status={entry.outcome} />
            <span class="text-xs text-muted"><.system_time at={entry.inserted_at} /></span>
          </div>
          <p class="whitespace-pre-wrap break-words"><.optional_value value={entry.comment} /></p>
        </li>
      </ol>
    </section>
    """
  end

  attr :status, :atom, required: true
  attr :role, :atom, required: true
  attr :latest, :any, required: true
  attr :last_decision, :any, required: true
  attr :can_decide, :boolean, required: true
  attr :current_user_id, :string, required: true

  def sign_bar(assigns) do
    ~H"""
    <section
      id="sign-bar"
      data-can-decide={to_string(@can_decide)}
      aria-label="검토 서명"
      class="sticky bottom-0 z-20 flex flex-wrap items-center justify-between gap-3 border-t border-base-300 bg-base-100 p-4 shadow-sm"
    >
      <%= if @status in [:approved, :rejected] && @last_decision do %>
        <div class="space-y-1">
          <div class="flex flex-wrap items-center gap-2">
            <.review_badge status={@status} /><span class="text-xs text-muted">{@last_decision.reviewer.email},
            <.system_time at={@last_decision.inserted_at} /></span>
          </div>
          <p :if={@status == :rejected} class="whitespace-pre-wrap break-words">
            {@last_decision.comment}
          </p>
        </div>
      <% end %>
      <%= cond do %>
        <% @status in [:approved, :rejected] -> %>
          <.review_badge :if={!@last_decision} status={@status} />
        <% @role == :preparer -> %>
          <p id="sign-bar-reason" class="text-xs text-muted">
            <.icon name="hero-lock-closed" class="size-4" /> 작성자는 승인, 반려할 수 없습니다 (직무분리)
          </p>
        <% @status == :open || is_nil(@latest) -> %>
          <p id="sign-bar-reason" class="text-xs text-muted">작성자 결론이 제출되지 않았습니다</p>
        <% @can_decide -> %>
          <div class="flex flex-wrap items-center gap-2">
            <span class="text-xs text-muted">작성자 판단</span><.conclusion_badge outcome={@latest.outcome} /><span class="text-xs text-muted">{@latest.preparer.email},
            <.system_time at={@latest.inserted_at} /></span>
          </div>
        <% @latest.preparer_id == @current_user_id -> %>
          <p id="sign-bar-reason" class="text-xs text-muted">본인이 제출한 결론은 승인, 반려할 수 없습니다.</p>
        <% true -> %>
          <p id="sign-bar-reason" class="text-xs text-muted">최신 결론을 확인한 뒤 결정하세요.</p>
      <% end %>
      <div :if={@status not in [:approved, :rejected]} class="flex items-center gap-2">
        <button
          id="finding-reject"
          type="button"
          disabled
          aria-describedby={if !@can_decide, do: "sign-bar-reason"}
          class="btn btn-sm btn-outline btn-error"
        >반려</button>
        <button
          id="finding-approve"
          type="button"
          disabled
          aria-describedby={if !@can_decide, do: "sign-bar-reason"}
          class="btn btn-sm btn-success"
        >승인</button>
      </div>
    </section>
    """
  end

  attr :value, :any, required: true

  defp optional_value(assigns) do
    ~H"""
    <%= if @value in [nil, ""] do %>
      -<span class="sr-only">없음</span>
    <% else %>
      {@value}
    <% end %>
    """
  end

  attr :value, :any, required: true

  defp money(assigns) do
    ~H"""
    <%= if Decimal.equal?(@value, 0) do %>
      -<span class="sr-only">0</span>
    <% else %>
      {Format.format_krw(@value)}
    <% end %>
    """
  end

  defp detail_value(value) when is_binary(value), do: value
  defp detail_value(nil), do: "-"
  defp detail_value(value), do: Jason.encode!(value, pretty: true)

  defp conclusion_style(nil), do: {"미판단", "badge-dash badge-neutral", "hero-pencil-square"}

  defp conclusion_style(:no_exception),
    do: {"이상 없음", "badge-outline badge-success", "hero-check-circle"}

  defp conclusion_style(:needs_follow_up),
    do: {"추가 확인 필요", "badge-outline badge-warning", "hero-question-mark-circle"}

  defp conclusion_style(:exception), do: {"예외", "badge-outline badge-error", "hero-flag"}
  defp review_color(:concluded), do: "badge-neutral"
  defp review_color(:approved), do: "badge-success"
  defp review_color(:rejected), do: "badge-error"
  defp review_icon(:concluded), do: "hero-clock"
  defp review_icon(:approved), do: "hero-check-badge"
  defp review_icon(:rejected), do: "hero-arrow-uturn-left"
  defp risk_color(:high), do: "badge-error"
  defp risk_color(:medium), do: "badge-warning"
  defp risk_color(:low), do: "badge-neutral"
  defp risk_icon(:high), do: "hero-exclamation-triangle"
  defp risk_icon(:medium), do: "hero-exclamation-circle"
  defp risk_icon(:low), do: "hero-minus-circle"
  defp risk_label(:high), do: "높음"
  defp risk_label(:medium), do: "중간"
  defp risk_label(:low), do: "낮음"
end
