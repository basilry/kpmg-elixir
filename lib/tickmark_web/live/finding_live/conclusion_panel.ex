defmodule TickmarkWeb.FindingLive.ConclusionPanel do
  @moduledoc "Preparer conclusion form and read-only summary."
  use TickmarkWeb, :html

  import TickmarkWeb.TestRunLive.Components, only: [system_time: 1]
  import TickmarkWeb.FindingLive.Badges

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
end
