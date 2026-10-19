defmodule Tickmark.Testing.Rules.OffHoursEntry do
  @moduledoc "Domain doc 2.3. entered_at is a KST wall clock, not a UTC timestamp."
  @behaviour Tickmark.Testing.Rule

  import Ecto.Query

  alias Tickmark.Ledger.JournalEntry
  alias Tickmark.Repo
  alias Tickmark.Testing.RuleContext

  @impl true
  def id, do: "off_hours_entry"
  @impl true
  def name, do: "업무시간 외 입력"
  @impl true
  def description, do: "업무 시작 전이나 종료 시각 이후에 입력된 수기 전표"
  @impl true
  def weight, do: 10

  @impl true
  def default_params do
    %{"apply_sources" => ["manual"], "business_start" => "08:00:00", "business_end" => "20:00:00"}
  end

  @impl true
  def run(%RuleContext{ledger_import_id: import_id, params: params}) do
    start_time = Time.from_iso8601!(params["business_start"])
    end_time = Time.from_iso8601!(params["business_end"])

    entries =
      Repo.all(
        from e in JournalEntry,
          where: e.ledger_import_id == ^import_id and e.source in ^params["apply_sources"],
          where:
            fragment("?::time", e.entered_at) < type(^start_time, :time) or
              fragment("?::time", e.entered_at) >= type(^end_time, :time),
          order_by: e.entry_number,
          select: map(e, [:id, :entered_at])
      )

    {:ok,
     Enum.map(entries, fn entry ->
       %{
         journal_entry_id: entry.id,
         reason: "업무시간 밖에 입력된 수기 전표",
         details: %{
           "entered_at" => NaiveDateTime.to_iso8601(entry.entered_at),
           "timezone" => "Asia/Seoul",
           "business_start" => Time.to_iso8601(start_time),
           "business_end" => Time.to_iso8601(end_time)
         }
       }
     end)}
  end
end
