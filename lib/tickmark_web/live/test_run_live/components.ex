defmodule TickmarkWeb.TestRunLive.Components do
  @moduledoc "Test run components: S4 progress and findings, and the run status S1 and S2 list."
  use TickmarkWeb, :html

  alias TickmarkWeb.Format

  attr :at, DateTime, required: true
  attr :seconds, :boolean, default: false

  def system_time(assigns) do
    ~H"""
    <time datetime={DateTime.to_iso8601(@at)} title={Format.utc_title(@at)} class="tabular-nums">
      {if @seconds, do: Format.format_kst(@at, :second), else: Format.format_kst(@at)}
    </time>
    """
  end

  attr :run, :any, required: true

  def test_progress(assigns) do
    rules = assigns.run.test_run_rules
    done = Enum.count(rules, &(&1.status in [:succeeded, :skipped, :failed]))
    failed = Enum.count(rules, &(&1.status == :failed))
    assigns = assign(assigns, done: done, failed: failed, theme: run_theme(assigns.run.status))

    ~H"""
    <section
      id="s4-main-2"
      aria-label="룰 진행"
      class="space-y-3 rounded-box border border-base-300 bg-base-100 p-4"
    >
      <div class="flex flex-wrap items-center justify-between gap-2 text-sm">
        <p
          id="s4-progress-summary"
          aria-live="polite"
          class={["flex flex-wrap items-center gap-2", @theme.text]}
        >
          <.icon
            name={@theme.icon}
            class={["size-4", @run.status == :running && "motion-safe:animate-spin"]}
          />
          {Format.run_status_label(@run.status)}
          <span class="tabular-nums">{@done} / {@run.rule_count} 룰</span>
          <span :if={@run.status != :running}>적중 전표 {Format.format_count(@run.finding_count)}건</span>
        </p>
        <p class="text-xs text-muted">
          <.system_time at={@run.started_at} seconds /> 시작
          <span :if={@run.finished_at}> - <.system_time at={@run.finished_at} seconds /> 완료</span>
          KST
        </p>
      </div>
      <progress
        id="s4-progress"
        class={["progress", @theme.progress]}
        value={@done}
        max={@run.rule_count}
        aria-label="룰 진행률"
      >{div(@done * 100, @run.rule_count)}%</progress>
      <ul id="s4-rules" class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <li
          :for={rule <- @run.test_run_rules}
          id={"s4-rule-#{rule.rule_id}"}
          class="space-y-1 text-sm"
        >
          <div class="flex items-center gap-1.5">
            <.icon
              name={rule_icon(rule.status)}
              class={[
                "size-4 shrink-0",
                rule_color(rule.status),
                rule.status == :running && "motion-safe:animate-spin"
              ]}
            />
            <span class="font-medium">{Format.rule_name(rule.rule_id)}</span>
          </div>
          <p class={["flex flex-wrap gap-x-2 text-xs", rule_color(rule.status)]}>
            <span>{Format.rule_status_label(rule.status)}</span>
            <%= case rule.status do %>
              <% :succeeded -> %>
                <span class="tabular-nums">{Format.format_count(rule.hit_count)}건</span>
              <% :failed -> %>
                <span>실행 실패, 로그 확인</span>
              <% :skipped -> %>
                <span>{rule.error}</span>
              <% :running -> %>
                <span>집계 중</span>
              <% :queued -> %>
                <span>-<span class="sr-only">없음</span></span>
            <% end %>
          </p>
        </li>
      </ul>
      <div :if={@failed > 0} id="s4-rule-failure" role="status" class="alert alert-warning text-sm">
        <.icon name="hero-exclamation-triangle" />
        <span>룰 {@failed}개를 실행하지 못했습니다. 그 룰은 점수에 넣지 않았습니다. 같은 GL로 다시 실행하면 처음부터 다시 계산합니다.</span>
      </div>
    </section>
    """
  end

  @doc "Run status as icon and text, for the S1 and S2 lists. nil (no run yet) shows `-`."
  attr :id, :string, default: nil
  attr :status, :atom, required: true

  def run_status(%{status: nil} = assigns) do
    ~H"""
    <span id={@id} class="text-muted">-<span class="sr-only">없음</span></span>
    """
  end

  def run_status(assigns) do
    assigns = assign(assigns, :theme, run_theme(assigns.status))

    ~H"""
    <span id={@id} class={["inline-flex items-center gap-1 whitespace-nowrap", @theme.text]}>
      <.icon
        name={@theme.icon}
        class={["size-4", @status == :running && "motion-safe:animate-spin"]}
      />
      {Format.run_status_label(@status)}
    </span>
    """
  end

  defp run_theme(:running),
    do: %{text: "text-primary", progress: "progress-primary", icon: "hero-arrow-path"}

  defp run_theme(:completed),
    do: %{text: "text-success", progress: "progress-success", icon: "hero-check"}

  defp run_theme(:completed_with_errors),
    do: %{text: "text-warning", progress: "progress-warning", icon: "hero-exclamation-triangle"}

  defp rule_icon(:queued), do: "hero-clock"
  defp rule_icon(:running), do: "hero-arrow-path"
  defp rule_icon(:succeeded), do: "hero-check"
  defp rule_icon(:skipped), do: "hero-minus-circle"
  defp rule_icon(:failed), do: "hero-x-circle"

  defp rule_color(:running), do: "text-primary"
  defp rule_color(:succeeded), do: "text-success"
  defp rule_color(:failed), do: "text-error"
  defp rule_color(_status), do: "text-muted"

  attr :rows, :any, required: true
  attr :engagement, :any, required: true
  attr :show_ai, :boolean, required: true

  def findings_table(assigns) do
    ~H"""
    <div id="s4-main-6" class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
      <table class="table table-pin-rows tk-table">
        <caption class="sr-only">적중 전표, 점수 내림차순</caption>
        <thead>
          <tr>
            <th scope="col">전표번호</th><th scope="col">전기일</th>
            <th scope="col" class="text-right">금액(원)</th><th scope="col" aria-sort="descending">
              점수
            </th>
            <th scope="col">적중 룰</th><th :if={@show_ai} id="s4-main-7" scope="col">AI 위험도</th>
            <th id="s4-main-8" scope="col">작성자 판단</th><th scope="col">검토</th>
          </tr>
        </thead>
        <tbody id="s4-findings" phx-update="stream">
          <tr id="s4-findings-empty" class="hidden only:table-row">
            <td colspan={if @show_ai, do: 8, else: 7} class="py-6 text-center text-sm text-muted">
              조건에 맞는 전표가 없습니다.
            </td>
          </tr>
          <tr :for={{dom_id, finding} <- @rows} id={dom_id} class="hover:bg-base-200">
            <td>
              <.link
                navigate={~p"/engagements/#{@engagement}/findings/#{finding}"}
                class="link link-hover font-mono slashed-zero whitespace-nowrap"
              >
                {finding.journal_entry.entry_number}
              </.link>
            </td>
            <td class="tabular-nums whitespace-nowrap">
              {Format.format_date(finding.journal_entry.posting_date)}
            </td>
            <td class="text-right tabular-nums whitespace-nowrap">
              {Format.format_krw(finding.journal_entry.total_debit)}
            </td>
            <td><.score score={finding.score} /></td>
            <td>
              <span
                :for={rule_id <- Format.sort_rule_ids(finding.rule_ids)}
                title={Format.rule_name(rule_id)}
                class="mr-1 whitespace-nowrap"
              >
                {Format.short_rule_name(rule_id)}
              </span>
            </td>
            <td :if={@show_ai} data-column="ai" class="text-muted">
              -<span class="sr-only">없음</span>
            </td>
            <td data-column="conclusion" class="text-muted">-<span class="sr-only">없음</span></td>
            <td data-column="review" class="whitespace-nowrap">
              {Format.review_status_label(finding.status)}<span
                :if={finding.status == :open}
                class="sr-only"
              >검토 전</span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :score, :integer, required: true

  defp score(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 whitespace-nowrap">
      <b class="w-7 text-right tabular-nums">{@score}</b>
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
end
