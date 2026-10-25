defmodule Tickmark.Testing.Rules.PeriodEndManual do
  @moduledoc "Domain doc 2.5. The engagement's year end window or adjustment period 13."
  @behaviour Tickmark.Testing.Rule

  import Ecto.Query

  alias Tickmark.Ledger.JournalEntry
  alias Tickmark.Repo
  alias Tickmark.Testing.RuleContext

  @impl true
  def id, do: "period_end_manual"
  @impl true
  def name, do: "기말 수기 전표"
  @impl true
  def description, do: "결산일 직전 구간이나 결산조정 기간에 전기된 수기 전표"
  @impl true
  def weight, do: 20

  @impl true
  def default_params, do: %{"apply_sources" => ["manual"], "period_end_window_days" => 3}

  @impl true
  def run(%RuleContext{ledger_import_id: import_id, engagement: engagement, params: params}) do
    end_date = engagement.period_end_date
    start_date = Date.add(end_date, 1 - params["period_end_window_days"])

    entries =
      Repo.all(
        from e in JournalEntry,
          where: e.ledger_import_id == ^import_id and e.source in ^params["apply_sources"],
          where:
            e.fiscal_period == 13 or
              (e.posting_date >= ^start_date and e.posting_date <= ^end_date),
          order_by: e.entry_number,
          select: map(e, [:id, :posting_date, :fiscal_period])
      )

    {:ok,
     Enum.map(entries, fn entry ->
       %{
         journal_entry_id: entry.id,
         reason: "기말 또는 결산조정 기간에 전기된 수기 전표",
         details: %{
           "posting_date" => Date.to_iso8601(entry.posting_date),
           "fiscal_period" => entry.fiscal_period,
           "window_start" => Date.to_iso8601(start_date),
           "period_end_date" => Date.to_iso8601(end_date)
         }
       }
     end)}
  end
end
