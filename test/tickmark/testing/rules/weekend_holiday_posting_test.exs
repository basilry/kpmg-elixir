Code.require_file("fixtures_helper.exs", __DIR__)

defmodule Tickmark.Testing.Rules.WeekendHolidayPostingTest do
  use Tickmark.DataCase, async: true
  import ExUnit.CaptureLog
  import Tickmark.Testing.Rules.Fixtures
  alias Tickmark.Testing.Rules.WeekendHolidayPosting, as: Rule

  setup do
    new_import()
  end

  test "weekend and weekday holiday each hit once, adjacent business days do not", ctx do
    entry(ctx, "JE-01", posting_date: ~D[2025-06-05])
    holiday = entry(ctx, "JE-02", posting_date: ~D[2025-06-06])
    saturday = entry(ctx, "JE-03", posting_date: ~D[2025-06-07])
    sunday = entry(ctx, "JE-04", posting_date: ~D[2025-06-08])
    entry(ctx, "JE-05", posting_date: ~D[2025-06-09])
    both = entry(ctx, "JE-06", posting_date: ~D[2025-03-01])
    entry(ctx, "JE-07", posting_date: ~D[2025-05-01])
    entry(ctx, "JE-08", posting_date: ~D[2025-12-31])

    [first, second, _, fourth] =
      assert_hits(Rule.run(context(ctx, Rule)), [holiday, saturday, sunday, both])

    assert first.details == %{
             "posting_date" => "2025-06-06",
             "day_of_week" => 5,
             "weekend" => false,
             "holiday" => true
           }

    assert second.details["weekend"]
    refute second.details["holiday"]
    assert fourth.details["weekend"] and fourth.details["holiday"]
  end

  test "sources, extra holidays and weekday settings are snapshot parameters", ctx do
    manual = entry(ctx, "JE-1", posting_date: ~D[2025-05-01])
    system = entry(ctx, "JE-2", posting_date: ~D[2025-05-03], source: :system)
    assert_hits(Rule.run(context(ctx, Rule)), [])
    assert_hits(Rule.run(context(ctx, Rule, %{"extra_holidays" => ["2025-05-01"]})), [manual])
    assert_hits(Rule.run(context(ctx, Rule, %{"apply_sources" => ["system"]})), [system])
    assert_hits(Rule.run(context(ctx, Rule, %{"weekend_days" => [4]})), [manual])
  end

  test "other imports are ignored and unknown years still check weekends with a warning", ctx do
    entry(new_import(), "OTHER", posting_date: ~D[2025-06-06])
    weekend = entry(ctx, "JE-1", posting_date: ~D[2026-01-03])
    entry(ctx, "JE-2", posting_date: ~D[2026-01-01])

    log = capture_log(fn -> assert_hits(Rule.run(context(ctx, Rule)), [weekend]) end)
    assert log =~ "2026년 휴일표 없음"
  end
end
