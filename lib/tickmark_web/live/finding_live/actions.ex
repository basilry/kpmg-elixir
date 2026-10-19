defmodule TickmarkWeb.FindingLive.Actions do
  @moduledoc "S5 form validation, submission and review confirmation state."
  import Phoenix.Component, only: [assign: 2, to_form: 1]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Tickmark.Review
  alias Tickmark.Review.{Conclusion, ReviewDecision}
  alias TickmarkWeb.FindingLive.State

  def new_conclusion_form, do: to_form(Conclusion.changeset(%Conclusion{}, %{}))
  def new_rejection_form, do: to_form(ReviewDecision.changeset(%ReviewDecision{}, %{}))

  def validate_conclusion(socket, params) do
    if socket.assigns.form_mode == :edit do
      # Validation prepares the next render, so its hidden reference must
      # match that render's card. Submission below still uses the incoming ID.
      triage = socket.assigns.triage
      params = Map.put(params, "ai_triage_id", triage && triage.id)
      changeset = Conclusion.changeset(%Conclusion{}, params)
      assign_conclusion_errors(socket, changeset)
    else
      socket
    end
  end

  def submit(socket, params) do
    # The hidden input identifies the suggestion actually rendered in the
    # browser. A newer server assign must never replace that submitted value.
    case Review.submit_conclusion(socket.assigns.current_scope, socket.assigns.finding, params) do
      {:ok, _conclusion} ->
        socket
        |> assign(form: new_conclusion_form(), comment_length: 0, conclusion_notice: nil)
        |> State.reload()
        |> put_flash(:info, "결론을 제출했습니다. 검토자에게 검토 대기로 보입니다.")

      {:error, %Ecto.Changeset{} = changeset} ->
        assign_conclusion_errors(socket, changeset)

      {:error, :invalid_state} ->
        socket |> State.reload() |> put_flash(:error, "승인된 항목은 수정할 수 없습니다.")

      {:error, :forbidden} ->
        put_flash(socket, :error, "결론을 제출할 권한이 없습니다.")
    end
  end

  def start_decision(socket, mode) when mode in [:approve, :reject] do
    if socket.assigns.can_decide do
      socket |> cancel_decision() |> assign(decision_mode: mode)
    else
      socket
    end
  end

  def cancel_decision(socket) do
    assign(socket,
      decision_mode: :idle,
      rejection_form: new_rejection_form(),
      rejection_length: 0
    )
  end

  def validate_rejection(socket, params) do
    if socket.assigns.decision_mode == :reject and socket.assigns.can_decide do
      changeset =
        ReviewDecision.changeset(%ReviewDecision{}, %{
          "decision" => "rejected",
          "comment" => params["comment"]
        })

      assign_rejection_errors(socket, changeset)
    else
      socket
    end
  end

  def decide(socket, conclusion_id, attrs) do
    # C-11: compare the ID from the final button/form, even after PubSub has
    # refreshed the server's latest conclusion. Review enforces permissions.
    case Review.decide(
           socket.assigns.current_scope,
           socket.assigns.finding,
           conclusion_id,
           attrs
         ) do
      {:ok, _decision} ->
        socket |> cancel_decision() |> State.reload()

      {:error, %Ecto.Changeset{} = changeset} ->
        assign_rejection_errors(socket, changeset)

      {:error, reason} ->
        socket = cancel_decision(socket)
        socket = if reason in [:invalid_state, :stale], do: State.reload(socket), else: socket
        put_flash(socket, :error, decision_error(reason))
    end
  end

  defp assign_conclusion_errors(socket, changeset) do
    messages = %{
      outcome: "판단을 선택하세요",
      comment: "코멘트를 입력하세요 (1-2000자)",
      ai_triage_id: "화면의 AI 제안을 다시 확인하세요"
    }

    assign(socket,
      form: changeset |> localize_errors(fn field, _opts -> messages[field] end) |> to_form(),
      comment_length: String.length(changeset.params["comment"] || "")
    )
  end

  defp assign_rejection_errors(socket, changeset) do
    form =
      changeset
      |> localize_errors(fn
        :comment, opts ->
          if opts[:validation] == :length,
            do: "반려 사유는 2000자 이하로 입력하세요",
            else: "반려 사유를 입력하세요"

        _field, _opts ->
          "최신 결론을 확인한 뒤 다시 결정하세요"
      end)
      |> to_form()

    assign(socket,
      decision_mode: :reject,
      rejection_form: form,
      rejection_length: String.length(changeset.params["comment"] || "")
    )
  end

  defp localize_errors(changeset, message) do
    errors =
      Enum.map(changeset.errors, fn {field, {_original, opts}} ->
        {field, {message.(field, opts), opts}}
      end)

    %{changeset | action: :validate, errors: errors}
  end

  defp decision_error(:invalid_state),
    do: "이 항목은 이미 처리되었습니다. 최신 상태로 다시 불러왔습니다."

  defp decision_error(:forbidden), do: "승인, 반려할 권한이 없습니다."
  defp decision_error(:self_review), do: "본인이 제출한 결론은 승인, 반려할 수 없습니다."

  defp decision_error(:stale),
    do: "작성자가 새 결론을 제출했습니다. 최신 결론을 확인한 뒤 다시 결정하세요."
end
