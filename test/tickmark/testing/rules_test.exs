defmodule Tickmark.Testing.RulesTest do
  use ExUnit.Case, async: true

  alias Tickmark.Testing.Rules

  test "registry preserves domain order, names and weights" do
    expected = [
      {"weekend_holiday_posting", "주말/공휴일 전기", 15},
      {"off_hours_entry", "업무시간 외 입력", 10},
      {"round_amount", "라운드 금액", 10},
      {"period_end_manual", "기말 수기 전표", 20},
      {"approval_control_gap", "승인 통제 이탈", 25},
      {"backdated_posting", "증빙일 괴리", 15},
      {"rare_account_pair", "희귀 계정 조합", 20},
      {"duplicate_entry", "중복 전표 의심", 15}
    ]

    assert Enum.map(Rules.all(), &{&1.id(), &1.name(), &1.weight()}) == expected
    assert Rules.ids() == Enum.map(expected, &elem(&1, 0))

    for rule <- Rules.all() do
      assert {:ok, ^rule} = Rules.fetch(rule.id())
      assert rule.description() =~ ~r/[가-힣]/u
      assert Jason.decode!(Jason.encode!(rule.default_params())) == rule.default_params()
    end
  end

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
