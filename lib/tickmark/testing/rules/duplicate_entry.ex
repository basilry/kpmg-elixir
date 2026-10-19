defmodule Tickmark.Testing.Rules.DuplicateEntry do
  @moduledoc """
  Domain doc 2.9. Compare counterparty, debit total and account/side sets.
  Only the later entry in (posting date, entered_at, entry number) order hits.
  If several earlier entries qualify, evidence names the earliest within the
  window. PostgreSQL groups the duplicate keys before the small candidate
  groups are checked against the date window in Elixir.
  """
  @behaviour Tickmark.Testing.Rule

  import Ecto.Query

  alias Tickmark.Ledger.{JournalEntry, JournalLine}
  alias Tickmark.Repo
  alias Tickmark.Testing.{Rule, RuleContext}

  @impl true
  def id, do: "duplicate_entry"
  @impl true
  def name, do: "중복 전표 의심"
  @impl true
  def description, do: "거래처·금액·계정 구성이 같고 가까운 날짜에 반복된 전표"
  @impl true
  def weight, do: 15

  @impl true
  def default_params do
    %{
      "apply_sources" => ["manual", "system"],
      "duplicate_window_days" => 7,
      "duplicate_min_amount" => 1_000_000
    }
  end

  @impl true
  def run(%RuleContext{ledger_import_id: import_id, params: params} = ctx) do
    candidates = candidates(ctx)

    groups_query =
      from c in subquery(candidates),
        group_by: [c.counterparty, c.amount, c.debit_accounts, c.credit_accounts],
        having: count() > 1,
        select: %{
          amount: c.amount,
          counterparty: c.counterparty,
          debit_accounts: c.debit_accounts,
          credit_accounts: c.credit_accounts,
          entry_ids: type(fragment("array_agg(?)", c.id), {:array, :binary_id})
        }

    groups = Repo.all(groups_query)

    entry_ids = Enum.flat_map(groups, & &1.entry_ids)

    entries =
      Repo.all(
        from e in JournalEntry,
          where: e.ledger_import_id == ^import_id and e.id in ^entry_ids,
          select: map(e, [:id, :entry_number, :posting_date, :entered_at])
      )
      |> Map.new(&{&1.id, &1})

    hits =
      groups
      |> Enum.flat_map(&group_matches(&1, entries, params["duplicate_window_days"]))
      |> Enum.sort_by(& &1.entry_number)
      |> Enum.map(&to_hit/1)

    {:ok, hits}
  end

  defp group_matches(group, entries, window_days) do
    sorted =
      group.entry_ids
      |> Enum.map(&Map.fetch!(entries, &1))
      |> Enum.sort_by(fn entry ->
        {Date.to_gregorian_days(entry.posting_date),
         NaiveDateTime.to_gregorian_seconds(entry.entered_at), entry.entry_number}
      end)

    # Keep only earlier entries still inside the window. Each entry enters and
    # leaves the FIFO once; a large repeated group never needs all pairings.
    {_queue, matches} =
      Enum.reduce(sorted, {:queue.new(), []}, fn entry, {queue, matches} ->
        queue = drop_expired(queue, entry.posting_date, window_days)

        matches =
          case :queue.peek(queue) do
            :empty ->
              matches

            {:value, earlier} ->
              match =
                group
                |> Map.merge(entry)
                |> Map.merge(%{
                  duplicate_of: earlier.entry_number,
                  original_posting_date: earlier.posting_date
                })

              [match | matches]
          end

        {:queue.in(entry, queue), matches}
      end)

    matches
  end

  defp drop_expired(queue, date, window_days) do
    case :queue.peek(queue) do
      {:value, earlier} ->
        if Date.diff(date, earlier.posting_date) > window_days,
          do: drop_expired(:queue.drop(queue), date, window_days),
          else: queue

      :empty ->
        queue
    end
  end

  defp candidates(%RuleContext{ledger_import_id: import_id, params: params}) do
    minimum = Decimal.new(params["duplicate_min_amount"])

    # Join headers to individual lines before aggregating. A correlated header
    # subquery was repeated for both the output and the counterparty filters;
    # a join to an already aggregated subquery can repeat the entire aggregate
    # when fresh imports have no useful planner statistics. The header selects
    # the import; lines are found by their journal_entry_id foreign key. An
    # extra line import filter can cause the whole import's bitmap to be built
    # again for every header when the planner underestimates the new rows.
    from l in JournalLine,
      join: e in JournalEntry,
      on: e.id == l.journal_entry_id,
      where: e.ledger_import_id == ^import_id and e.source in ^params["apply_sources"],
      where: not is_nil(e.counterparty) and e.counterparty != "",
      group_by: [l.journal_entry_id, e.counterparty],
      having: sum(l.debit) >= ^minimum,
      select: %{
        id: l.journal_entry_id,
        counterparty: e.counterparty,
        amount: sum(l.debit),
        debit_accounts:
          fragment(
            "array_agg(DISTINCT ? ORDER BY ?) FILTER (WHERE ? > 0)",
            l.account_code,
            l.account_code,
            l.debit
          ),
        credit_accounts:
          fragment(
            "array_agg(DISTINCT ? ORDER BY ?) FILTER (WHERE ? > 0)",
            l.account_code,
            l.account_code,
            l.credit
          )
      }
  end

  defp to_hit(entry) do
    %{
      journal_entry_id: entry.id,
      reason: "#{entry.duplicate_of} 전표와 거래처·금액·계정 구성이 같은 후속 전표",
      details: %{
        "duplicate_of" => entry.duplicate_of,
        "counterparty" => entry.counterparty,
        "entry_amount" => Rule.amount_string(entry.amount),
        "posting_date" => Date.to_iso8601(entry.posting_date),
        "original_posting_date" => Date.to_iso8601(entry.original_posting_date),
        "gap_days" => Date.diff(entry.posting_date, entry.original_posting_date),
        "debit_accounts" => entry.debit_accounts,
        "credit_accounts" => entry.credit_accounts
      }
    }
  end
end
