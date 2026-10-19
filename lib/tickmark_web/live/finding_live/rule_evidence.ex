defmodule TickmarkWeb.FindingLive.RuleEvidence do
  @moduledoc "Rule hits and the score calculation."
  use TickmarkWeb, :html

  alias TickmarkWeb.Format

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

  defp detail_value(value) when is_binary(value), do: value
  defp detail_value(nil), do: "-"
  defp detail_value(value), do: Jason.encode!(value, pretty: true)
end
