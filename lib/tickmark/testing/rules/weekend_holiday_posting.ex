defmodule Tickmark.Testing.Rules.WeekendHolidayPosting do
  @moduledoc "Domain doc 2.2. Manual postings on weekends or listed holidays."
  @behaviour Tickmark.Testing.Rule

  import Ecto.Query
  require Logger

  alias Tickmark.Ledger.JournalEntry
  alias Tickmark.Repo
  alias Tickmark.Testing.{Holidays, RuleContext}

  @impl true
  def id, do: "weekend_holiday_posting"
  @impl true
  def name, do: "주말/공휴일 전기"
  @impl true
  def description, do: "주말이나 공휴일에 전기된 수기 전표"
  @impl true
  def weight, do: 15

  @impl true
  def default_params do
    %{
      "apply_sources" => ["manual"],
      # ISO weekdays: Monday = 1, Sunday = 7. Dates survive a JSON round trip.
      "weekend_days" => [6, 7],
      "holiday_table" => Enum.map(Holidays.all(), &Date.to_iso8601/1),
      "extra_holidays" => []
    }
  end

  @impl true
  def run(%RuleContext{ledger_import_id: import_id, params: params}) do
    table = Enum.map(params["holiday_table"], &Date.from_iso8601!/1)
    holidays = MapSet.new(table ++ Enum.map(params["extra_holidays"], &Date.from_iso8601!/1))

    entries =
      Repo.all(
        from e in JournalEntry,
          where: e.ledger_import_id == ^import_id and e.source in ^params["apply_sources"],
          order_by: e.entry_number,
          select: map(e, [:id, :posting_date])
      )

    warn_missing_years(entries, table)

    hits =
      Enum.flat_map(entries, fn entry ->
        weekend? = Date.day_of_week(entry.posting_date) in params["weekend_days"]
        holiday? = MapSet.member?(holidays, entry.posting_date)

        if weekend? or holiday? do
          [
            %{
              journal_entry_id: entry.id,
              reason: "주말 또는 공휴일에 전기된 수기 전표",
              details: %{
                "posting_date" => Date.to_iso8601(entry.posting_date),
                "day_of_week" => Date.day_of_week(entry.posting_date),
                "weekend" => weekend?,
                "holiday" => holiday?
              }
            }
          ]
        else
          []
        end
      end)

    {:ok, hits}
  end

  defp warn_missing_years(entries, table) do
    covered = MapSet.new(table, & &1.year)

    entries
    |> Enum.map(& &1.posting_date.year)
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(covered, &1))
    |> Enum.each(&Logger.warning("주말/공휴일 전기: #{&1}년 휴일표 없음"))
  end
end
