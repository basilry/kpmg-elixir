defmodule Tickmark.Ledger.GeneratorTest do
  use ExUnit.Case, async: true

  alias NimbleCSV.RFC4180, as: CSV
  alias Tickmark.Ledger.Generator
  alias Tickmark.Testing.Holidays

  # 아래 표는 생성기 코드를 보지 않고 문서에서 다시 옮겼다. 생성기와 같은 실수를 하지 않기 위해서다.

  # MVP 문서 5장 GL 계약
  @columns ~w(entry_number line_number posting_date document_date entered_at fiscal_year
              fiscal_period account_code account_name debit credit description counterparty
              entered_by approved_by source)
  @header_fields ~w(posting_date document_date entered_at fiscal_year fiscal_period entered_by
                    approved_by source counterparty)

  # 도메인 문서 7.6
  @label_columns ~w(entry_number label scenario_id expected_rules expected_score expected_triage probe)

  # 도메인 문서 2.1
  @weights %{
    "weekend_holiday_posting" => 15,
    "off_hours_entry" => 10,
    "round_amount" => 10,
    "period_end_manual" => 20,
    "approval_control_gap" => 25,
    "backdated_posting" => 15,
    "rare_account_pair" => 20,
    "duplicate_entry" => 15
  }

  # 도메인 문서 7.2
  @account_codes ~w(1010 1020 1110 1150 1220 1240 1310 1330 1520 1590 2110 2120 2130 2140 2150
                    2160 2210 3110 3210 4110 4290 5110 5210 5230 5240 5250 5260 5280 5290 5320
                    5410 5510)

  # 도메인 문서 7.4 희귀 쌍 카탈로그 R1-R8 {차변, 대변}
  @catalog_pairs [
    {"1020", "3210"},
    {"5260", "4290"},
    {"1010", "4110"},
    {"3110", "5510"},
    {"1150", "4110"},
    {"5240", "1240"},
    {"5210", "2120"},
    {"1520", "4290"}
  ]

  # 도메인 문서 7.3, 7.4 건수
  @scenario_counts %{
    "I1" => 30,
    "I2" => 30,
    "I3" => 30,
    "I4" => 25,
    "I5" => 30,
    "I6" => 25,
    "I7" => 12,
    "I8" => 15,
    "C1" => 8,
    "C2" => 6,
    "C3" => 4,
    "C4" => 4,
    "B1" => 12,
    "B2" => 10,
    "B3" => 8,
    "B4" => 16
  }
  # 정상 패턴 쿼터 8,264건에서 제자리 변이(I1-I6, C1, C2, C4) 188건을 뺀 수
  @clean_count 8_264 - 188

  @seeds [Generator.default_seed(), 1, 42, 20_261_017]

  setup_all do
    runs =
      Map.new(@seeds, fn seed ->
        result = Generator.generate(seed: seed)

        {seed,
         %{
           result: result,
           entries: parse_gl(result.gl_csv),
           labels: parse_labels(result.labels_csv)
         }}
      end)

    %{runs: runs}
  end

  describe "결정성" do
    test "같은 시드는 같은 바이트, 다른 시드는 다른 출력" do
      first = Generator.generate()

      assert Generator.generate(seed: Generator.default_seed()) == first
      assert Generator.generate() == first

      other = Generator.generate(seed: 7)
      assert other.gl_csv != first.gl_csv
      assert other.labels_csv != first.labels_csv
    end

    test "알 수 없는 옵션은 거부한다" do
      assert_raise ArgumentError, fn -> Generator.generate(rows: 100) end
    end
  end

  test "GL CSV 가 MVP 문서 5장 계약을 지킨다", %{runs: runs} do
    for seed <- @seeds do
      %{result: result, entries: entries} = runs[seed]
      gl = result.gl_csv

      refute String.starts_with?(gl, "﻿")
      assert String.valid?(gl)

      [header | rows] = CSV.parse_string(gl, skip_headers: false)
      assert header == @columns
      assert length(rows) == result.line_count
      assert length(entries) == result.entry_count
      assert result.line_count in 19_400..20_600

      for row <- rows, do: assert_row(Map.new(Enum.zip(@columns, row)))

      numbers = Enum.map(entries, & &1.number)
      assert numbers == Enum.uniq(numbers), "seed #{seed}: 같은 전표의 행이 떨어져 있다"

      for entry <- entries do
        assert Enum.map(entry.rows, & &1["line_number"]) ==
                 Enum.map(1..length(entry.rows), &Integer.to_string/1)

        headers = Enum.map(entry.rows, &Map.take(&1, @header_fields))
        assert length(Enum.uniq(headers)) == 1, "#{entry.number}: 헤더 필드가 행마다 다르다"

        credit = Enum.sum(for {_code, _debit, credit} <- entry.lines, do: credit)
        assert entry.amount == credit, "#{entry.number}: 차대 불균형"

        assert entry.fiscal_period == entry.posting_date.month or
                 (entry.fiscal_period == 13 and entry.posting_date == ~D[2025-12-31])
      end
    end
  end

  test "라벨이 전표와 1:1 이고 점수와 건수가 도메인 문서 7.6 과 맞다", %{runs: runs} do
    for seed <- @seeds do
      %{entries: entries, labels: labels} = runs[seed]

      assert length(labels) == length(entries)
      assert MapSet.new(labels, & &1.number) == MapSet.new(entries, & &1.number)

      for label <- labels do
        assert label.rules == Enum.sort(label.rules)
        assert label.score == min(100, Enum.sum(Enum.map(label.rules, &Map.fetch!(@weights, &1))))
        assert label.triage == to_string(label.score >= 25)
        assert label.probe in ["true", "false"]

        case label.label do
          "clean" -> assert label.rules == [] and String.starts_with?(label.scenario, "N")
          "benign_trigger" -> assert String.starts_with?(label.scenario, "B")
          "anomaly" -> assert String.first(label.scenario) in ["I", "C"]
        end
      end

      assert Enum.count(labels, &(&1.triage == "true")) == 52, "seed #{seed}"
      assert Enum.count(labels, &(&1.score in 1..24)) == 213, "seed #{seed}"
      assert Enum.count(labels, &(&1.label == "clean")) == @clean_count

      counts = labels |> Enum.reject(&(&1.label == "clean")) |> Enum.frequencies_by(& &1.scenario)
      assert counts == @scenario_counts, "seed #{seed}"

      probes = Enum.filter(labels, &(&1.probe == "true"))
      assert length(probes) == 5
      assert Enum.all?(probes, &(&1.scenario in ["C2", "C4"]))
    end
  end

  # 도메인 문서 2.2-2.9 판정을 GL CSV 만으로 다시 계산한 참조 구현.
  # 10/19 룰 엔진 대신 쓰는 것이 아니라, 생성기가 라벨대로 데이터를 만들었는지 확인하는 용도다.
  test "GL 로 다시 계산한 적중 룰이 모든 전표에서 expected_rules 와 같다", %{runs: runs} do
    for seed <- @seeds do
      %{entries: entries, labels: labels} = runs[seed]
      actual = actual_rules(entries)

      mismatches =
        for label <- labels, actual[label.number] != label.rules do
          {label.number, label.scenario, expected: label.rules, actual: actual[label.number]}
        end

      assert mismatches == [], "seed #{seed}: #{inspect(Enum.take(mismatches, 10))}"
    end
  end

  test "시나리오 안의 건수 배분이 도메인 문서 7.3, 7.4 와 맞다", %{runs: runs} do
    for seed <- @seeds do
      %{entries: entries, labels: labels} = runs[seed]
      scenario = Map.new(labels, &{&1.number, &1.scenario})
      by_scenario = Enum.group_by(entries, &scenario[&1.number])
      weekend? = &(Date.day_of_week(&1.posting_date) >= 6)
      gap = &Date.diff(&1.posting_date, &1.document_date)

      assert Enum.count(by_scenario["I1"], weekend?) == 20
      assert Enum.count(by_scenario["I2"], &(&1.entered_at.hour >= 22)) == 15
      assert Enum.count(by_scenario["I2"], &(&1.entered_at.hour < 6)) == 15
      assert Enum.count(by_scenario["I4"], &(&1.fiscal_period == 13)) == 8
      assert Enum.count(by_scenario["I5"], &(&1.approved_by == "")) == 15
      assert Enum.count(by_scenario["I6"], &(gap.(&1) in 31..90)) == 18
      assert Enum.count(by_scenario["I6"], &(gap.(&1) in -15..-1)) == 7
      assert Enum.count(by_scenario["C1"], weekend?) == 4

      assert Enum.all?(by_scenario["I8"], &(&1.posting_date.month in 2..12))
      assert Enum.all?(by_scenario["B1"], &(&1.amount == 11_000_000))
      assert Enum.all?(by_scenario["B2"], &(&1.fiscal_period == 12 and &1.posting_date.day >= 29))
      assert Enum.all?(by_scenario["B3"], &(Date.day_of_week(&1.posting_date) == 6))

      assert Enum.all?(by_scenario["B4"], fn entry ->
               entry.amount in 100_000_000..500_000_000 and rem(entry.amount, 1_000_000) == 0
             end)
    end
  end

  test "희귀 쌍 불변식 I-1 ~ I-4 (도메인 문서 7.5)", %{runs: runs} do
    for seed <- @seeds do
      %{entries: entries, labels: labels} = runs[seed]
      counts = pair_counts(entries)
      scenario = Map.new(labels, &{&1.number, &1.scenario})

      # I-1
      assert length(entries) >= 500

      # I-3
      for pair <- @catalog_pairs do
        assert Map.get(counts, pair, 0) == 2, "seed #{seed}: #{inspect(pair)}"
      end

      # I-2: 카탈로그 밖의 쌍은 모두 6건 이상 (최소는 N23)
      rare = Enum.reject(counts, fn {pair, count} -> pair in @catalog_pairs or count >= 6 end)
      assert rare == [], "seed #{seed}: #{inspect(rare)}"

      # I-4: 카탈로그 쌍은 I7, C3 전표에만 있다
      for entry <- entries, Enum.any?(pairs(entry), &(&1 in @catalog_pairs)) do
        assert scenario[entry.number] in ["I7", "C3"]
      end
    end
  end

  defp assert_row(row) do
    assert row["entry_number"] =~ ~r/^JE2025-\d{6}$/
    assert row["line_number"] =~ ~r/^[1-9]\d*$/
    assert {:ok, _} = Date.from_iso8601(row["posting_date"])
    assert {:ok, _} = Date.from_iso8601(row["document_date"])
    assert row["entered_at"] =~ ~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/
    assert row["fiscal_year"] == "2025"
    assert String.to_integer(row["fiscal_period"]) in 1..13
    assert row["account_code"] in @account_codes
    assert row["account_name"] != ""
    assert row["debit"] =~ ~r/^(0|[1-9]\d*)$/
    assert row["credit"] =~ ~r/^(0|[1-9]\d*)$/
    assert Enum.count([row["debit"], row["credit"]], &(&1 != "0")) == 1
    assert row["source"] in ["manual", "system"]
    assert row["entered_by"] != ""
    assert String.length(row["description"]) <= 500

    for {column, value} <- Map.delete(row, "description") do
      assert String.length(value) <= 200, "#{column} 가 200자를 넘는다"
    end
  end

  defp parse_gl(gl) do
    [_header | rows] = CSV.parse_string(gl, skip_headers: false)

    rows
    |> Enum.map(&Map.new(Enum.zip(@columns, &1)))
    |> Enum.chunk_by(& &1["entry_number"])
    |> Enum.map(&to_entry/1)
  end

  defp to_entry([first | _] = rows) do
    lines =
      Enum.map(rows, fn row ->
        {row["account_code"], String.to_integer(row["debit"]), String.to_integer(row["credit"])}
      end)

    %{
      number: first["entry_number"],
      rows: rows,
      posting_date: Date.from_iso8601!(first["posting_date"]),
      document_date: Date.from_iso8601!(first["document_date"]),
      entered_at: NaiveDateTime.from_iso8601!(first["entered_at"]),
      fiscal_period: String.to_integer(first["fiscal_period"]),
      source: first["source"],
      entered_by: first["entered_by"],
      approved_by: first["approved_by"],
      counterparty: first["counterparty"],
      lines: lines,
      amount: Enum.sum(for {_code, debit, _credit} <- lines, do: debit)
    }
  end

  defp parse_labels(csv) do
    [header | rows] = CSV.parse_string(csv, skip_headers: false)
    assert header == @label_columns

    Enum.map(rows, fn [number, label, scenario, rules, score, triage, probe] ->
      %{
        number: number,
        label: label,
        scenario: scenario,
        rules: if(rules == "", do: [], else: String.split(rules, ";")),
        score: String.to_integer(score),
        triage: triage,
        probe: probe
      }
    end)
  end

  defp actual_rules(entries) do
    counts = pair_counts(entries)
    population_ok? = length(entries) >= 500
    duplicates = duplicate_hits(entries)

    Map.new(entries, fn entry ->
      manual? = entry.source == "manual"
      hour = entry.entered_at.hour
      gap = Date.diff(entry.posting_date, entry.document_date)
      day = Date.day_of_week(entry.posting_date)

      hits = [
        {"weekend_holiday_posting",
         manual? and (day >= 6 or Holidays.holiday?(entry.posting_date))},
        {"off_hours_entry", manual? and (hour < 8 or hour >= 20)},
        {"round_amount",
         manual? and entry.amount >= 10_000_000 and rem(entry.amount, 1_000_000) == 0},
        {"period_end_manual",
         manual? and
           (entry.fiscal_period == 13 or Date.diff(~D[2025-12-31], entry.posting_date) in 0..2)},
        {"approval_control_gap",
         manual? and entry.amount >= 1_000_000 and
           entry.approved_by in ["", entry.entered_by]},
        {"backdated_posting", gap >= 30 or gap < 0},
        {"rare_account_pair",
         population_ok? and Enum.any?(pairs(entry), &(Map.fetch!(counts, &1) <= 2))},
        {"duplicate_entry", MapSet.member?(duplicates, entry.number)}
      ]

      {entry.number, for({rule, true} <- hits, do: rule) |> Enum.sort()}
    end)
  end

  defp pairs(entry) do
    debits = for {code, debit, _credit} <- entry.lines, debit > 0, do: code
    credits = for {code, _debit, credit} <- entry.lines, credit > 0, do: code
    Enum.uniq(for debit <- debits, credit <- credits, do: {debit, credit})
  end

  defp pair_counts(entries), do: entries |> Enum.flat_map(&pairs/1) |> Enum.frequencies()

  # 같은 거래처, 금액, {(계정, 차대)} 집합이고 전기일 차이 7일 이하인 앞선 전표가 있으면 나중 것만 적중
  defp duplicate_hits(entries) do
    entries
    |> Enum.filter(&(&1.counterparty != "" and &1.amount >= 1_000_000))
    |> Enum.group_by(&{&1.counterparty, &1.amount, signature(&1)})
    |> Enum.flat_map(fn {_key, group} ->
      sorted =
        Enum.sort_by(group, fn entry ->
          {Date.to_gregorian_days(entry.posting_date),
           NaiveDateTime.to_gregorian_seconds(entry.entered_at), entry.number}
        end)

      for {later, index} <- Enum.with_index(sorted),
          earlier <- Enum.take(sorted, index),
          Date.diff(later.posting_date, earlier.posting_date) <= 7,
          uniq: true,
          do: later.number
    end)
    |> MapSet.new()
  end

  defp signature(entry) do
    entry.lines
    |> Enum.map(fn {code, debit, _credit} -> {code, if(debit > 0, do: :debit, else: :credit)} end)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
