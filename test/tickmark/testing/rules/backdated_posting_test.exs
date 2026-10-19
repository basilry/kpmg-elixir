Code.require_file("fixtures_helper.exs", __DIR__)

defmodule Tickmark.Testing.Rules.BackdatedPostingTest do
  use Tickmark.DataCase, async: true
  import Tickmark.Testing.Rules.Fixtures
  alias Tickmark.Testing.Rules.BackdatedPosting, as: Rule

  setup do
    new_import()
  end

  test "30 days late is inclusive, forward tolerance is strict, both sources qualify", ctx do
    entry(ctx, "JE-1", posting_date: ~D[2025-03-31], document_date: ~D[2025-03-02])
    late = entry(ctx, "JE-2", posting_date: ~D[2025-03-31], document_date: ~D[2025-03-01])
    entry(ctx, "JE-3", posting_date: ~D[2025-03-31], document_date: ~D[2025-03-31])

    early =
      entry(ctx, "JE-4",
        posting_date: ~D[2025-03-31],
        document_date: ~D[2025-04-01],
        source: :system
      )

    [hit, forward] = assert_hits(Rule.run(context(ctx, Rule)), [late, early])

    assert hit.details == %{
             "posting_date" => "2025-03-31",
             "document_date" => "2025-03-01",
             "gap_days" => 30,
             "backdate_days" => 30,
             "forward_tolerance_days" => 0
           }

    assert forward.details["gap_days"] == -1
  end

  test "custom tolerances, source filter and import scope", ctx do
    entry(ctx, "JE-1", document_date: ~D[2025-04-02])
    early = entry(ctx, "JE-2", document_date: ~D[2025-04-03])
    system = entry(ctx, "JE-3", document_date: ~D[2025-03-01], source: :system)
    entry(new_import(), "OTHER", document_date: ~D[2025-01-01])

    assert_hits(
      Rule.run(context(ctx, Rule, %{"forward_tolerance_days" => 2, "backdate_days" => 31})),
      [early]
    )

    assert_hits(Rule.run(context(ctx, Rule, %{"apply_sources" => ["system"]})), [system])
  end
end
