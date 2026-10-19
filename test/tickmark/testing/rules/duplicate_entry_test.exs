Code.require_file("fixtures_helper.exs", __DIR__)

defmodule Tickmark.Testing.Rules.DuplicateEntryTest do
  use Tickmark.DataCase, async: true
  import Tickmark.Testing.Rules.Fixtures
  alias Tickmark.Testing.Rules.DuplicateEntry, as: Rule

  setup do
    new_import()
  end

  test "seven calendar days is inclusive, eight days and amounts below minimum are excluded",
       ctx do
    entry(ctx, "JE-1", posting_date: ~D[2025-01-01])
    later = entry(ctx, "JE-2", posting_date: ~D[2025-01-08])
    entry(ctx, "JE-3", posting_date: ~D[2025-02-01], counterparty: "C002")
    entry(ctx, "JE-4", posting_date: ~D[2025-02-09], counterparty: "C002")
    small = [{"1110", :debit, "999999"}, {"4110", :credit, "999999"}]
    entry(ctx, "JE-5", %{counterparty: "C003"}, small)
    entry(ctx, "JE-6", %{counterparty: "C003"}, small)
    [hit] = assert_hits(Rule.run(context(ctx, Rule)), [later])

    assert hit.details == %{
             "duplicate_of" => "JE-1",
             "counterparty" => "C001",
             "entry_amount" => "1000000",
             "posting_date" => "2025-01-08",
             "original_posting_date" => "2025-01-01",
             "gap_days" => 7,
             "debit_accounts" => ["1110"],
             "credit_accounts" => ["4110"]
           }

    assert_hits(Rule.run(context(ctx, Rule, %{"duplicate_window_days" => 6})), [])
  end

  test "orders by posting date, then input timestamp, then number; multiple predecessors yield one hit",
       ctx do
    # Deliberately insert and number in a different order from chronology.
    late = entry(ctx, "JE-1", posting_date: ~D[2025-04-02], entered_at: ~N[2025-03-01 01:00:00])
    entry(ctx, "JE-9", posting_date: ~D[2025-04-01], entered_at: ~N[2025-04-01 08:00:00])
    middle = entry(ctx, "JE-2", posting_date: ~D[2025-04-01], entered_at: ~N[2025-04-01 09:00:00])
    tie = entry(ctx, "JE-3", posting_date: ~D[2025-04-01], entered_at: ~N[2025-04-01 09:00:00])
    hits = assert_hits(Rule.run(context(ctx, Rule)), [late, middle, tie])
    assert Enum.all?(hits, &(&1.details["duplicate_of"] == "JE-9"))
  end

  test "equal timestamps use entry number as the final tie breaker", ctx do
    later = entry(ctx, "JE-B")
    entry(ctx, "JE-A")
    [hit] = assert_hits(Rule.run(context(ctx, Rule)), [later])
    assert hit.details["duplicate_of"] == "JE-A"
  end

  test "a chain chooses the earliest predecessor still inside the window", ctx do
    entry(ctx, "JE-1", posting_date: ~D[2025-01-01])
    second = entry(ctx, "JE-2", posting_date: ~D[2025-01-08])
    third = entry(ctx, "JE-3", posting_date: ~D[2025-01-09])
    entry(ctx, "JE-4", posting_date: ~D[2025-01-18])

    [first_hit, second_hit] = assert_hits(Rule.run(context(ctx, Rule)), [second, third])
    assert first_hit.details["duplicate_of"] == "JE-1"
    assert second_hit.details["duplicate_of"] == "JE-2"
  end

  test "account-side sets ignore line order, repetitions and per-line allocations", ctx do
    entry(ctx, "JE-1", %{}, [
      {"1110", :debit, "300000"},
      {"1150", :debit, "700000"},
      {"4110", :credit, "1000000"}
    ])

    later =
      entry(ctx, "JE-2", %{}, [
        {"4110", :credit, "1000000"},
        {"1150", :debit, "100000"},
        {"1110", :debit, "400000"},
        {"1150", :debit, "500000"}
      ])

    # Same total and codes, but reversed sides must not match.
    entry(ctx, "JE-3", %{}, [
      {"4110", :debit, "1000000"},
      {"1110", :credit, "300000"},
      {"1150", :credit, "700000"}
    ])

    entry(ctx, "JE-4", %{}, [{"1110", :debit, "1000000"}, {"4110", :credit, "1000000"}])
    [hit] = assert_hits(Rule.run(context(ctx, Rule)), [later])
    assert hit.details["debit_accounts"] == ["1110", "1150"]
  end

  test "different counterparties and amounts, absent counterparties and other imports cannot match",
       ctx do
    entry(ctx, "JE-1")
    entry(ctx, "JE-2", counterparty: "C002")
    entry(ctx, "JE-3", %{}, [{"1110", :debit, "1000001"}, {"4110", :credit, "1000001"}])

    for {number, party} <- [{"JE-4", nil}, {"JE-5", nil}, {"JE-6", ""}, {"JE-7", ""}] do
      entry(ctx, number, counterparty: party)
    end

    entry(new_import(), "OTHER")
    assert_hits(Rule.run(context(ctx, Rule)), [])
  end

  test "both sources qualify by default, apply_sources and amount threshold narrow candidates",
       ctx do
    entry(ctx, "JE-1")
    manual = entry(ctx, "JE-2")
    entry(ctx, "JE-3", source: :system, counterparty: "C002")
    system = entry(ctx, "JE-4", source: :system, counterparty: "C002")
    assert_hits(Rule.run(context(ctx, Rule)), [manual, system])
    assert_hits(Rule.run(context(ctx, Rule, %{"apply_sources" => ["system"]})), [system])
    assert_hits(Rule.run(context(ctx, Rule, %{"duplicate_min_amount" => 1_000_001})), [])
  end

  test "uses summed line amounts rather than cached header totals", ctx do
    entry(ctx, "JE-1")

    later =
      entry(ctx, "JE-2",
        total_debit: Decimal.new("9000000"),
        total_credit: Decimal.new("9000000")
      )

    [hit] = assert_hits(Rule.run(context(ctx, Rule)), [later])
    assert hit.details["entry_amount"] == "1000000"
  end
end
