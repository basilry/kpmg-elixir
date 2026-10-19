Code.require_file("fixtures_helper.exs", __DIR__)

defmodule Tickmark.Testing.Rules.PeriodEndManualTest do
  use Tickmark.DataCase, async: true
  import Tickmark.Testing.Rules.Fixtures
  alias Tickmark.Testing.Rules.PeriodEndManual, as: Rule

  setup do
    new_import()
  end

  test "year end window includes both ends and period 13 independently qualifies", ctx do
    entry(ctx, "JE-1", posting_date: ~D[2025-12-28])
    first = entry(ctx, "JE-2", posting_date: ~D[2025-12-29])
    last = entry(ctx, "JE-3", posting_date: ~D[2025-12-31])
    entry(ctx, "JE-4", posting_date: ~D[2026-01-01])
    adjustment = entry(ctx, "JE-5", posting_date: ~D[2026-01-01], fiscal_period: 13)
    entry(ctx, "JE-6", posting_date: ~D[2025-11-30])
    both = entry(ctx, "JE-7", posting_date: ~D[2025-12-31], fiscal_period: 13)
    [hit | _] = assert_hits(Rule.run(context(ctx, Rule)), [first, last, adjustment, both])

    assert hit.details == %{
             "posting_date" => "2025-12-29",
             "fiscal_period" => 3,
             "window_start" => "2025-12-29",
             "period_end_date" => "2025-12-31"
           }
  end

  test "uses engagement end date, custom window and source filter, within one import", ctx do
    ctx = %{ctx | engagement: %{ctx.engagement | period_end_date: ~D[2025-06-30]}}
    entry(ctx, "JE-1", posting_date: ~D[2025-06-28])
    manual = entry(ctx, "JE-2", posting_date: ~D[2025-06-29])
    system = entry(ctx, "JE-3", posting_date: ~D[2025-06-30], source: :system)
    entry(new_import(), "OTHER", posting_date: ~D[2025-06-30])
    assert_hits(Rule.run(context(ctx, Rule, %{"period_end_window_days" => 2})), [manual])
    assert_hits(Rule.run(context(ctx, Rule, %{"apply_sources" => ["system"]})), [system])
  end
end
