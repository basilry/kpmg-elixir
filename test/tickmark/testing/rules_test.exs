defmodule Tickmark.Testing.RulesTest do
  use ExUnit.Case, async: true

  alias Tickmark.Testing.Rules

  test "every registered module agrees with its registry id" do
    for {id, module} <- Enum.zip(Rules.ids(), Rules.all()) do
      assert module.id() == id
      assert id =~ ~r/^[a-z][a-z0-9_]{1,39}$/
      assert module.weight() in 1..100
      assert Enum.all?(Map.keys(module.default_params()), &is_binary/1)
    end
  end

  test "fetch/1 finds real and test-only rules, all/0 lists only real ones" do
    assert {:ok, Tickmark.Testing.Rules.ApprovalControlGap} = Rules.fetch("approval_control_gap")
    assert {:ok, Tickmark.TestRules.Skip} = Rules.fetch("test_skip")
    assert :error = Rules.fetch("no_such_rule")
    refute "test_skip" in Rules.ids()
  end

  test "amount_string/1 gives whole won without the column scale" do
    assert Tickmark.Testing.Rule.amount_string(Decimal.new("1000000.00")) == "1000000"
    assert Tickmark.Testing.Rule.amount_string(Decimal.new("0")) == "0"
  end
end
