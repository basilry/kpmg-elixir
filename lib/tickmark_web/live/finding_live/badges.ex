defmodule TickmarkWeb.FindingLive.Badges do
  @moduledoc "Score, AI risk and human review badges for S5."
  use TickmarkWeb, :html

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
