Code.require_file("fixtures_helper.exs", __DIR__)

defmodule Tickmark.Testing.Rules.OffHoursEntryTest do
  use Tickmark.DataCase, async: true
  import Tickmark.Testing.Rules.Fixtures
  alias Tickmark.Testing.Rules.OffHoursEntry, as: Rule

  setup do
    new_import()
  end

  test "08:00 is included and 20:00 excluded from business hours, in KST", ctx do
    morning = entry(ctx, "JE-1", entered_at: ~N[2025-04-01 07:59:59])
    entry(ctx, "JE-2", entered_at: ~N[2025-04-01 08:00:00])
    entry(ctx, "JE-3", entered_at: ~N[2025-04-01 19:59:59])
    evening = entry(ctx, "JE-4", entered_at: ~N[2025-04-01 20:00:00])
    midnight = entry(ctx, "JE-5", entered_at: ~N[2025-04-01 00:00:00])
    [first | _] = assert_hits(Rule.run(context(ctx, Rule)), [morning, evening, midnight])

    assert first.details == %{
             "entered_at" => "2025-04-01T07:59:59",
             "timezone" => "Asia/Seoul",
             "business_start" => "08:00:00",
             "business_end" => "20:00:00"
           }
  end

  test "source and clock bounds are configurable and another import is ignored", ctx do
    manual = entry(ctx, "JE-1", entered_at: ~N[2025-04-01 08:59:59])
    system = entry(ctx, "JE-2", entered_at: ~N[2025-04-01 23:59:59], source: :system)
    entry(new_import(), "OTHER", entered_at: ~N[2025-04-01 23:59:59])
    assert_hits(Rule.run(context(ctx, Rule)), [])
    assert_hits(Rule.run(context(ctx, Rule, %{"business_start" => "09:00:00"})), [manual])
    assert_hits(Rule.run(context(ctx, Rule, %{"apply_sources" => ["system"]})), [system])
  end
end
