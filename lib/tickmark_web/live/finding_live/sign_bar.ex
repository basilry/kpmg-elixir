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
  attr :decision_mode, :atom, required: true
  attr :rejection_form, Phoenix.HTML.Form, required: true
  attr :rejection_length, :integer, required: true

  def sign_bar(assigns) do
    ~H"""
    <section
      id="sign-bar"
      data-can-decide={to_string(@can_decide)}
      data-mode={@decision_mode}
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
      <div
        :if={@can_decide && @decision_mode == :approve}
        id="approval-confirmation"
        class="flex flex-wrap items-center gap-2"
      >
        <p>승인하시겠습니까?</p>
        <button
          id="finding-decision-cancel"
          type="button"
          phx-click="cancel_decision"
          class="btn btn-sm"
        >취소</button>
        <button
          id="finding-confirm-approve"
          type="button"
          phx-click="confirm_approve"
          phx-value-conclusion-id={@latest.id}
          phx-disable-with="승인 중..."
          class="btn btn-sm btn-success"
        >승인 확정</button>
      </div>
      <.form
        :if={@can_decide && @decision_mode == :reject}
        for={@rejection_form}
        id="rejection-form"
        phx-change="validate_rejection"
        phx-submit="confirm_reject"
        phx-value-conclusion-id={@latest.id}
        class="w-full space-y-2"
      >
        <.input
          field={@rejection_form[:comment]}
          id="rejection-comment"
          type="textarea"
          label="반려 사유 (필수)"
          rows="3"
          aria-describedby="rejection-character-count"
        />
        <div class="flex flex-wrap items-center justify-between gap-2">
          <span id="rejection-character-count" class="text-xs text-muted tabular-nums">
            {@rejection_length} / 2000
          </span>
          <div class="flex gap-2">
            <button
              id="finding-decision-cancel"
              type="button"
              phx-click="cancel_decision"
              class="btn btn-sm"
            >취소</button>
            <button
              id="finding-confirm-reject"
              type="submit"
              phx-value-conclusion-id={@latest.id}
              phx-disable-with="반려 중..."
              class="btn btn-sm btn-error"
            >반려 확정</button>
          </div>
        </div>
      </.form>
      <div
        :if={@status not in [:approved, :rejected] && (!@can_decide || @decision_mode == :idle)}
        class="flex items-center gap-2"
      >
        <button
          id="finding-reject"
          type="button"
          disabled={!@can_decide}
          phx-click="start_reject"
          aria-describedby={if !@can_decide, do: "sign-bar-reason"}
          class="btn btn-sm btn-outline btn-error"
        >반려</button>
        <button
          id="finding-approve"
          type="button"
          disabled={!@can_decide}
          phx-click="start_approve"
          aria-describedby={if !@can_decide, do: "sign-bar-reason"}
          class="btn btn-sm btn-success"
        >승인</button>
      </div>
    </section>
    """
  end
end
