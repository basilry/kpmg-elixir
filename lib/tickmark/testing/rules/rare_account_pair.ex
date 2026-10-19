defmodule Tickmark.Testing.Rules.RareAccountPair do
  @moduledoc """
  Domain doc 2.8. Count entries containing each debit/credit account pair.
  Frequency and minimum population always use the entire import; apply_sources
  only restricts which entries can be returned as hits.
  """
  @behaviour Tickmark.Testing.Rule

  import Ecto.Query

  alias Tickmark.Ledger.{JournalEntry, JournalLine}
  alias Tickmark.Repo
  alias Tickmark.Testing.RuleContext

  @impl true
  def id, do: "rare_account_pair"
  @impl true
  def name, do: "희귀 계정 조합"
  @impl true
  def description, do: "모집단에서 드물게 함께 쓰인 차변·대변 계정 조합을 포함한 전표"
  @impl true
  def weight, do: 20

  @impl true
  def default_params do
    %{
      "apply_sources" => ["manual", "system"],
      "rare_max_count" => 2,
      "rare_min_population" => 500
    }
  end

  @impl true
  def run(%RuleContext{ledger_import_id: import_id, params: params} = ctx) do
    population =
      Repo.aggregate(from(e in JournalEntry, where: e.ledger_import_id == ^import_id), :count)

    if population < params["rare_min_population"] do
      {:skip, "모집단 전표 수 #{population}건이 최소 #{params["rare_min_population"]}건 미만"}
    else
      {:ok, find_hits(ctx, population)}
    end
  end

  defp find_hits(%RuleContext{ledger_import_id: import_id, params: params}, population) do
    # Aggregate each entry first, then expand only its own debit/credit sets.
    # Lateral unnest avoids joining the whole lines population to itself.
    entry_accounts =
      from l in JournalLine,
        where: l.ledger_import_id == ^import_id,
        group_by: l.journal_entry_id,
        select: %{
          id: l.journal_entry_id,
          debit_accounts:
            fragment("array_agg(DISTINCT ?) FILTER (WHERE ? > 0)", l.account_code, l.debit),
          credit_accounts:
            fragment("array_agg(DISTINCT ?) FILTER (WHERE ? > 0)", l.account_code, l.credit)
        }

    # Count entries, not lines; only rare pairs and their entry ids leave SQL.
    rare_pairs =
      Repo.all(
        from e in subquery(entry_accounts),
          cross_lateral_join: d in fragment("SELECT unnest(?) AS account_code", e.debit_accounts),
          cross_lateral_join:
            c in fragment("SELECT unnest(?) AS account_code", e.credit_accounts),
          group_by: [d.account_code, c.account_code],
          having: count(e.id, :distinct) <= ^params["rare_max_count"],
          order_by: [d.account_code, c.account_code],
          select: %{
            debit_account: d.account_code,
            credit_account: c.account_code,
            entry_count: count(e.id, :distinct),
            entry_ids: type(fragment("array_agg(DISTINCT ?)", e.id), {:array, :binary_id})
          }
      )

    evidence =
      Enum.reduce(rare_pairs, %{}, fn pair, acc ->
        details = %{
          "debit_account" => pair.debit_account,
          "credit_account" => pair.credit_account,
          "entry_count" => pair.entry_count
        }

        Enum.reduce(pair.entry_ids, acc, fn id, acc ->
          Map.update(acc, id, [details], &(&1 ++ [details]))
        end)
      end)

    entry_ids = Map.keys(evidence)

    Repo.all(
      from e in JournalEntry,
        where: e.ledger_import_id == ^import_id and e.source in ^params["apply_sources"],
        where: e.id in ^entry_ids,
        order_by: e.entry_number,
        select: e.id
    )
    |> Enum.map(fn id ->
      %{
        journal_entry_id: id,
        reason: "모집단에서 드문 차변·대변 계정 조합을 포함한 전표",
        details: %{
          "population_count" => population,
          "rare_max_count" => params["rare_max_count"],
          "rare_pairs" => Map.fetch!(evidence, id)
        }
      }
    end)
  end
end
