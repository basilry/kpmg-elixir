defmodule TickmarkWeb.FindingLive.State do
  @moduledoc "Refreshes stored finding data without discarding a preparer draft."
  import Phoenix.Component, only: [assign: 2, to_form: 1]
  import Phoenix.LiveView, only: [stream: 4]

  alias Tickmark.Testing

  def reload(socket) do
    finding = Testing.get_finding!(socket.assigns.current_scope, socket.assigns.finding.id)
    refresh_finding(socket, finding)
  end

  def refresh_finding(socket, finding) do
    hits = Testing.list_rule_results(socket.assigns.current_scope, finding)

    triage =
      if finding.triage_status == :succeeded and
           finding.score >= finding.test_run.triage_threshold,
         do: List.first(finding.ai_triages)

    latest_conclusion = List.last(finding.conclusions)
    lines = finding.journal_entry.lines
    total_debit = Enum.reduce(lines, Decimal.new(0), &Decimal.add(&1.debit, &2))
    total_credit = Enum.reduce(lines, Decimal.new(0), &Decimal.add(&1.credit, &2))

    description =
      case List.first(lines) do
        nil -> nil
        line -> line.description
      end

    # Only the displayed suggestion reference changes; draft fields and their
    # validation errors survive updates made by another person or the AI.
    form =
      socket.assigns.form.source
      |> Ecto.Changeset.put_change(:ai_triage_id, visible_triage_id(triage))
      |> to_form()

    form_mode =
      cond do
        finding.status == :approved -> :locked
        socket.assigns.role == :preparer -> :edit
        true -> :read_only
      end

    can_decide =
      socket.assigns.role == :reviewer and finding.status == :concluded and
        not is_nil(latest_conclusion) and
        latest_conclusion.preparer_id != socket.assigns.current_scope.user.id

    socket
    |> assign(
      finding: finding,
      entry: finding.journal_entry,
      entry_description: description,
      triage: triage,
      latest_conclusion: latest_conclusion,
      last_decision: List.last(finding.review_decisions),
      form_mode: form_mode,
      can_decide: can_decide,
      form: form,
      total_debit: total_debit,
      total_credit: total_credit,
      balanced: Decimal.equal?(total_debit, total_credit),
      score_formula: score_formula(finding.score, hits),
      history_empty?: finding.conclusions == [] and finding.review_decisions == []
    )
    |> stream(:entry_lines, lines, reset: true)
    |> stream(:rule_hits, hits, reset: true)
    |> stream(:history, history_entries(finding), reset: true)
  end

  defp visible_triage_id(nil), do: nil
  defp visible_triage_id(triage), do: triage.id

  defp score_formula(score, hits) do
    sum = Enum.map_join(hits, " + ", &Integer.to_string(&1.score))

    cond do
      hits == [] -> "점수 #{score}"
      Enum.sum(Enum.map(hits, & &1.score)) > 100 -> "점수 #{score} = min(100, #{sum})"
      true -> "점수 #{score} = #{sum}"
    end
  end

  defp history_entries(finding) do
    conclusions =
      Enum.map(finding.conclusions, fn conclusion ->
        %{
          id: "conclusion-#{conclusion.id}",
          kind: :conclusion,
          actor: conclusion.preparer.email,
          outcome: conclusion.outcome,
          comment: conclusion.comment,
          inserted_at: conclusion.inserted_at
        }
      end)

    decisions =
      Enum.map(finding.review_decisions, fn decision ->
        %{
          id: "decision-#{decision.id}",
          kind: :decision,
          actor: decision.reviewer.email,
          outcome: decision.decision,
          comment: decision.comment,
          inserted_at: decision.inserted_at
        }
      end)

    Enum.sort_by(conclusions ++ decisions, fn entry ->
      {DateTime.to_unix(entry.inserted_at, :microsecond), entry.kind == :decision, entry.id}
    end)
  end
end
