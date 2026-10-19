defmodule TickmarkWeb.FormatTest do
  use ExUnit.Case, async: true

  alias Tickmark.Testing.Rules
  alias TickmarkWeb.Format

  test "the eight short names follow the design system and unknown ids stay intact" do
    for {id, label} <- [
          {"weekend_holiday_posting", "휴일"},
          {"off_hours_entry", "시간 외"},
          {"round_amount", "라운드"},
          {"period_end_manual", "기말 수기"},
          {"approval_control_gap", "승인 이탈"},
          {"backdated_posting", "증빙일"},
          {"rare_account_pair", "희귀 조합"},
          {"duplicate_entry", "중복"}
        ] do
      assert Format.short_rule_name(id) == label
    end

    assert Format.short_rule_name("future_rule") == "future_rule"
    assert Format.rule_name("approval_control_gap") == "승인 통제 이탈"
    assert Format.rule_name("future_rule") == "future_rule"
  end

  test "stored alphabetical ids are restored to registry order with unknown ids last" do
    ids = Rules.ids()
    assert Format.sort_rule_ids(Enum.sort(ids)) == ids
    assert Format.sort_rule_ids(["zzz", "aaa" | Enum.reverse(ids)]) == ids ++ ["aaa", "zzz"]
    assert Format.sort_rule_ids([]) == []
  end

  test "KRW uses comma groups, keeps nonzero fractions and shows a minus sign" do
    assert Format.format_krw(12_000_000) == "12,000,000"
    assert Format.format_krw(Decimal.new("225000000.00")) == "225,000,000"
    assert Format.format_krw(Decimal.new("-1250000.5")) == "-1,250,000.50"
    assert Format.format_krw(Decimal.new("1234.01")) == "1,234.01"
    assert Format.format_krw(0) == "0"
    assert Format.format_krw(nil) == "-"
    assert Format.format_count(19_804) == "19,804"
  end

  test "dates use ISO dates and system times shift to KST across midnight" do
    utc = ~U[2025-12-31 15:42:10.123456Z]
    assert Format.format_date(~D[2025-12-31]) == "2025-12-31"
    assert Format.format_date(nil) == "-"
    assert Format.format_kst(utc) == "2026-01-01 00:42"
    assert Format.format_kst(utc, :second) == "2026-01-01 00:42:10"
    assert Format.utc_title(utc) == "2025-12-31 15:42:10 UTC"
    assert Format.format_kst(nil) == "-"
  end

  test "GL entered_at is already a KST wall clock value" do
    assert Format.format_kst(~N[2025-12-30 23:42:10]) == "2025-12-30 23:42"
    assert Format.format_kst(~N[2025-12-30 23:42:10], :second) == "2025-12-30 23:42:10"
  end
end
