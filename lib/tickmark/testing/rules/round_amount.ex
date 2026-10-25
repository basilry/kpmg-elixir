defmodule Tickmark.Testing.Rules.RoundAmount do
  @moduledoc "Domain doc 2.4. Compare the sum of debit lines using exact numeric arithmetic."
  @behaviour Tickmark.Testing.Rule

  import Ecto.Query

  alias Tickmark.Ledger.{JournalEntry, JournalLine}
  alias Tickmark.Repo
  alias Tickmark.Testing.{Rule, RuleContext}

  @impl true
  def id, do: "round_amount"
  @impl true
  def name, do: "라운드 금액"
  @impl true
  def description, do: "기준 금액 이상이며 일정 금액 단위로 나누어떨어지는 수기 전표"
  @impl true
  def weight, do: 10

  @impl true
  def default_params do
    %{"apply_sources" => ["manual"], "round_min_amount" => 10_000_000, "round_unit" => 1_000_000}
  end

  @impl true
  def run(%RuleContext{ledger_import_id: import_id, params: params}) do
    minimum = Decimal.new(params["round_min_amount"])
    unit = Decimal.new(params["round_unit"])

    amounts =
      Repo.all(
        from l in JournalLine,
          where: l.ledger_import_id == ^import_id,
          group_by: l.journal_entry_id,
          having: sum(l.debit) >= ^minimum,
          having: fragment("mod(?, ?)", sum(l.debit), ^unit) == 0,
          select: {l.journal_entry_id, sum(l.debit)}
      )
      |> Map.new()

    entry_ids = Map.keys(amounts)

    entries =
      Repo.all(
        from e in JournalEntry,
          where: e.ledger_import_id == ^import_id and e.source in ^params["apply_sources"],
          where: e.id in ^entry_ids,
          order_by: e.entry_number,
          select: e.id
      )

    {:ok,
     Enum.map(entries, fn id ->
       %{
         journal_entry_id: id,
         reason: "기준 금액 이상인 라운드 금액 수기 전표",
         details: %{
           "entry_amount" => Rule.amount_string(Map.fetch!(amounts, id)),
           "round_min_amount" => Rule.amount_string(minimum),
           "round_unit" => Rule.amount_string(unit)
         }
       }
     end)}
  end
end
