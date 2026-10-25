Code.require_file("fixtures_helper.exs", __DIR__)

defmodule Tickmark.Testing.Rules.RareAccountPairTest do
  use Tickmark.DataCase, async: true
  import Tickmark.Testing.Rules.Fixtures
  alias Tickmark.Testing.Rules.RareAccountPair, as: Rule

  setup do
    new_import()
  end

  test "population 499 skips and 500 runs; another import does not count", ctx do
    for index <- 1..499 do
      entry(ctx, "NORMAL-#{index}")
    end

    entry(new_import(), "OTHER")
    assert {:skip, reason} = Rule.run(context(ctx, Rule))
    assert reason =~ "499"
    assert reason =~ "500"
    rare = pair(ctx, "RARE", "1020", "3210")
    [hit] = assert_hits(Rule.run(context(ctx, Rule)), [rare])
    assert hit.details["population_count"] == 500
  end

  test "counts distinct entries, returns all rare Cartesian pairs in one hit", ctx do
    lines = [
      {"1010", :debit, "250000"},
      {"1010", :debit, "250000"},
      {"1020", :debit, "500000"},
      {"4110", :credit, "500000"},
      {"4290", :credit, "250000"},
      {"4290", :credit, "250000"}
    ]

    first = entry(ctx, "JE-1", %{}, lines)
    second = entry(ctx, "JE-2", %{source: :system}, lines)
    # A third entry takes just this pair over the inclusive rare_max_count.
    pair(ctx, "JE-3", "1010", "4110")
    single = pair(ctx, "JE-4", "1150", "3210")

    [hit, other, one] =
      assert_hits(Rule.run(context(ctx, Rule, %{"rare_min_population" => 1})), [
        first,
        second,
        single
      ])

    assert hit.details == %{
             "population_count" => 4,
             "rare_max_count" => 2,
             "rare_pairs" => [
               %{"debit_account" => "1010", "credit_account" => "4290", "entry_count" => 2},
               %{"debit_account" => "1020", "credit_account" => "4110", "entry_count" => 2},
               %{"debit_account" => "1020", "credit_account" => "4290", "entry_count" => 2}
             ]
           }

    assert other.details == hit.details
    assert [%{"entry_count" => 1}] = one.details["rare_pairs"]

    assert_hits(
      Rule.run(context(ctx, Rule, %{"rare_min_population" => 1, "rare_max_count" => 1})),
      [single]
    )
  end

  test "source filter restricts hits but frequencies use the full scoped population", ctx do
    manual = pair(ctx, "JE-1", "1020", "3210")
    system = pair(ctx, "JE-2", "1020", "3210", %{source: :system})
    pair(new_import(), "OTHER", "1020", "3210")
    params = %{"rare_min_population" => 1, "apply_sources" => ["manual"]}
    [hit] = assert_hits(Rule.run(context(ctx, Rule, params)), [manual])
    assert [%{"entry_count" => 2}] = hit.details["rare_pairs"]

    assert_hits(Rule.run(context(ctx, Rule, Map.put(params, "apply_sources", ["system"]))), [
      system
    ])

    pair(ctx, "JE-3", "1020", "3210", %{source: :system})
    assert_hits(Rule.run(context(ctx, Rule, params)), [])
  end

  defp pair(ctx, number, debit, credit, attrs \\ %{}) do
    entry(ctx, number, attrs, [{debit, :debit, "1000000"}, {credit, :credit, "1000000"}])
  end
end
