Code.require_file("fixtures_helper.exs", __DIR__)

defmodule Tickmark.Testing.Rules.RoundAmountTest do
  use Tickmark.DataCase, async: true
  import Tickmark.Testing.Rules.Fixtures
  alias Tickmark.Testing.Rules.RoundAmount, as: Rule

  setup do
    new_import()
  end

  test "threshold is inclusive and exact multiples are required", ctx do
    entry_amount(ctx, "JE-1", "9999999")
    entry_amount(ctx, "JE-2", "9000000")
    exact = entry_amount(ctx, "JE-3", "10000000")
    entry_amount(ctx, "JE-4", "10000001")
    above = entry_amount(ctx, "JE-5", "11000000")
    [hit, _] = assert_hits(Rule.run(context(ctx, Rule)), [exact, above])

    assert hit.details == %{
             "entry_amount" => "10000000",
             "round_min_amount" => "10000000",
             "round_unit" => "1000000"
           }
  end

  test "sums debit lines, not individual lines or cached header totals", ctx do
    split =
      entry(ctx, "JE-1", %{}, [
        {"1110", :debit, "4500000"},
        {"1150", :debit, "5500000"},
        {"4110", :credit, "10000000"}
      ])

    entry(ctx, "JE-2", %{
      total_debit: Decimal.new("20000000"),
      total_credit: Decimal.new("20000000")
    })

    assert_hits(Rule.run(context(ctx, Rule)), [split])
  end

  test "source, unit and minimum are configurable and imports are isolated", ctx do
    manual = entry_amount(ctx, "JE-1", "1500000")
    system = entry_amount(ctx, "JE-2", "10000000", %{source: :system})
    entry_amount(new_import(), "OTHER", "10000000")
    assert_hits(Rule.run(context(ctx, Rule)), [])

    assert_hits(
      Rule.run(context(ctx, Rule, %{"round_min_amount" => 1_000_000, "round_unit" => 500_000})),
      [manual]
    )

    assert_hits(Rule.run(context(ctx, Rule, %{"apply_sources" => ["system"]})), [system])
  end

  defp entry_amount(ctx, number, amount, attrs \\ %{}) do
    entry(ctx, number, attrs, [{"1110", :debit, amount}, {"4110", :credit, amount}])
  end
end
