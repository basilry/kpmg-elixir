defmodule Tickmark.Testing.Rules.ApprovalControlGapTest do
  use Tickmark.DataCase, async: true

  import Tickmark.AccountsFixtures
  import Tickmark.SchemaFixtures

  alias Tickmark.Testing.RuleContext
  alias Tickmark.Testing.Rules.ApprovalControlGap

  setup do
    user = user_fixture()
    engagement = insert_engagement(user)
    %{engagement: engagement, ledger_import: insert_ledger_import(engagement, user)}
  end

  test "flags manual entries with no approver or a self-approval at or above the threshold",
       ctx do
    missing = insert(ctx, "JE-1", approved_by: nil)
    self_approved = insert(ctx, "JE-2", approved_by: "kim.jh")
    _approved = insert(ctx, "JE-3", approved_by: "park.sy")
    _small = insert(ctx, "JE-4", approved_by: nil, amount: "999999")
    _system = insert(ctx, "JE-5", approved_by: nil, source: :system)

    assert {:ok, [first, second]} = ApprovalControlGap.run(context(ctx))

    assert first.journal_entry_id == missing.id
    assert first.details["gap"] == "missing_approver"
    assert first.details["entry_amount"] == "1000000"

    assert second.journal_entry_id == self_approved.id
    assert second.details["gap"] == "self_approved"
    assert second.details["approved_by"] == "kim.jh"
  end

  test "only reads the given import", ctx do
    insert(ctx, "JE-1", approved_by: nil)
    other = insert_ledger_import(ctx.engagement, user_fixture())

    assert {:ok, []} = ApprovalControlGap.run(%{context(ctx) | ledger_import_id: other.id})
  end

  defp insert(ctx, entry_number, opts) do
    amount = Decimal.new(Keyword.get(opts, :amount, "1000000"))

    insert_journal_entry(ctx.ledger_import, %{
      entry_number: entry_number,
      entered_by: "kim.jh",
      approved_by: Keyword.fetch!(opts, :approved_by),
      source: Keyword.get(opts, :source, :manual),
      total_debit: amount,
      total_credit: amount
    })
  end

  defp context(ctx) do
    %RuleContext{
      test_run_id: Ecto.UUID.generate(),
      ledger_import_id: ctx.ledger_import.id,
      engagement: ctx.engagement,
      params: ApprovalControlGap.default_params()
    }
  end
end
