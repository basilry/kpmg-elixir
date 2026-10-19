defmodule TickmarkWeb.FindingLive.SignBar do
  @moduledoc "Reviewer signature and separation-of-duties guidance."
  use TickmarkWeb, :html

  import TickmarkWeb.TestRunLive.Components, only: [system_time: 1]
  import TickmarkWeb.FindingLive.Badges

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
end
