defmodule TickmarkWeb.FindingLive.History do
  @moduledoc "Chronological conclusion and review history."
  use TickmarkWeb, :html

  import TickmarkWeb.TestRunLive.Components, only: [system_time: 1]
  import TickmarkWeb.FindingLive.Badges
  import TickmarkWeb.FindingLive.Components

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
end
