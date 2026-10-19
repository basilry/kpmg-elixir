defmodule Tickmark.Testing.Rules.Fixtures do
  @moduledoc false

  import ExUnit.Assertions
  import Tickmark.AccountsFixtures
  import Tickmark.SchemaFixtures

  alias Tickmark.Ledger.JournalLine
  alias Tickmark.Repo
  alias Tickmark.Testing.RuleContext

  def new_import do
    user = user_fixture()
    engagement = insert_engagement(user)
    %{engagement: engagement, ledger_import: insert_ledger_import(engagement, user)}
  end

  def context(ctx, rule, params \\ %{}) do
    %RuleContext{
      test_run_id: Ecto.UUID.generate(),
      ledger_import_id: ctx.ledger_import.id,
      engagement: ctx.engagement,
      params: Map.merge(rule.default_params(), params)
    }
  end

  def entry(ctx, number, attrs \\ %{}, lines \\ nil) do
    lines = lines || [{"1110", :debit, "1000000"}, {"4110", :credit, "1000000"}]

    total =
      Enum.reduce(lines, Decimal.new(0), fn
        {_code, :debit, amount}, acc -> Decimal.add(acc, Decimal.new(amount))
        {_code, :credit, _amount}, acc -> acc
      end)

    record =
      insert_journal_entry(
        ctx.ledger_import,
        Map.merge(
          %{
            entry_number: number,
            counterparty: "C001",
            approved_by: "manager01",
            total_debit: total,
            total_credit: total,
            line_count: length(lines)
          },
          Map.new(attrs)
        )
      )

    for {{code, side, amount}, index} <- Enum.with_index(lines, 1) do
      %JournalLine{
        journal_entry_id: record.id,
        ledger_import_id: ctx.ledger_import.id,
        line_number: index,
        account_code: code,
        account_name: "합성 계정",
        debit: if(side == :debit, do: Decimal.new(amount), else: Decimal.new(0)),
        credit: if(side == :credit, do: Decimal.new(amount), else: Decimal.new(0))
      }
      |> Repo.insert!()
    end

    record
  end

  def assert_hits({:ok, hits}, entries) do
    assert Enum.map(hits, & &1.journal_entry_id) == Enum.map(entries, & &1.id)
    assert length(hits) == length(Enum.uniq_by(hits, & &1.journal_entry_id))

    for hit <- hits do
      assert hit.reason =~ ~r/[가-힣]/u
      refute hit.reason =~ "\n"
      assert Jason.decode!(Jason.encode!(hit.details)) == hit.details
      assert_string_keys(hit.details)
    end

    hits
  end

  defp assert_string_keys(map) when is_map(map) do
    assert Enum.all?(Map.keys(map), &is_binary/1)
    Enum.each(Map.values(map), &assert_string_keys/1)
  end

  defp assert_string_keys(list) when is_list(list), do: Enum.each(list, &assert_string_keys/1)
  defp assert_string_keys(_), do: :ok
end
