defmodule Tickmark.Testing.Rules.ApprovalControlGap do
  @moduledoc """
  Domain doc 2.6. A manual entry at or above the amount threshold that was
  approved by nobody or by the person who entered it.

  This is the reference rule for the others: a read-only query scoped to
  one import, Decimal comparisons inside SQL, string-keyed params.
  """
  @behaviour Tickmark.Testing.Rule

  import Ecto.Query

  alias Tickmark.Ledger.JournalEntry
  alias Tickmark.Repo
  alias Tickmark.Testing.{Rule, RuleContext}

  @impl true
  def id, do: "approval_control_gap"

  @impl true
  def name, do: "승인 통제 이탈"

  @impl true
  def description,
    do: "승인자가 없거나 입력자가 직접 승인한 일정 금액 이상의 수기 전표"

  @impl true
  def weight, do: 25

  @impl true
  def default_params do
    %{"apply_sources" => ["manual"], "approval_min_amount" => 1_000_000}
  end

  @impl true
  def run(%RuleContext{ledger_import_id: import_id, params: params}) do
    min_amount = Decimal.new(params["approval_min_amount"])

    entries =
      Repo.all(
        from e in JournalEntry,
          where: e.ledger_import_id == ^import_id,
          where: e.source in ^params["apply_sources"],
          where: e.total_debit >= ^min_amount,
          where: is_nil(e.approved_by) or e.approved_by == e.entered_by,
          order_by: e.entry_number,
          select: map(e, [:id, :entered_by, :approved_by, :total_debit])
      )

    {:ok, Enum.map(entries, &to_hit/1)}
  end

  defp to_hit(entry) do
    gap = if is_nil(entry.approved_by), do: "missing_approver", else: "self_approved"

    %{
      journal_entry_id: entry.id,
      reason: reason(gap),
      details: %{
        "gap" => gap,
        "entered_by" => entry.entered_by,
        "approved_by" => entry.approved_by,
        "entry_amount" => Rule.amount_string(entry.total_debit)
      }
    }
  end

  defp reason("missing_approver"), do: "승인자 없이 전기된 수기 전표"
  defp reason("self_approved"), do: "입력자가 직접 승인한 수기 전표"
end
