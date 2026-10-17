defmodule Tickmark.Ledger.Generator.Builder do
  @moduledoc """
  `Catalog` 패턴 하나를 건수만큼 전표로 만든다 (도메인 문서 7.3 공통 규칙).

  `gen` 은 생성 상태 `%{rand: 난수 상태, dup_keys: 등록된 중복 키, next_id: 다음 전표 id}` 이고
  모든 함수가 새 `gen` 을 돌려준다.
  """

  alias Tickmark.Ledger.Generator.{Catalog, Dates, Entry, Random}

  # 수기: 09:00:00 - 17:59:59 같은 날 입력, 증빙일 0-7일 이전
  @business_hours {32_400, 64_799}
  @manual_document_gap 7
  # 자동: 00:10:00 - 05:00:00 입력, 증빙일 0-3일 이전
  @batch_hours {600, 18_000}
  @system_document_gap 3

  # 도메인 문서 2.4 round_amount 파라미터. 수기 전표가 우연히 라운드 금액이 되지 않게 할 때 쓴다.
  @round_unit 1_000_000
  @round_min_amount 10_000_000

  @monthly_days [:month_end, :rent_day]

  def build_all(patterns, gen), do: Enum.flat_map_reduce(patterns, gen, &build/2)

  def build(pattern, gen) do
    Enum.map_reduce(1..pattern.count//1, gen, fn index, gen -> build_one(pattern, index, gen) end)
  end

  defp build_one(pattern, index, gen) do
    {posting_date, rand} = posting_date(pattern.days, index, gen.rand)
    {header, rand} = header(pattern, posting_date, rand)
    {counterparty, rand} = counterparty(pattern.party, rand)

    entry =
      Map.merge(header, %{
        id: gen.next_id,
        scenario: pattern.scenario,
        label: pattern.label,
        rules: pattern.rules,
        probe: false,
        counterparty: counterparty,
        description: description(pattern, posting_date),
        lines: []
      })

    {entry, gen} = put_lines(entry, pattern, %{gen | rand: rand})
    {entry, %{gen | next_id: gen.next_id + 1}}
  end

  # 월 단위 패턴(건수 12)은 index 가 곧 월이다.
  defp posting_date(:any, _index, rand), do: Random.pick(Dates.any_days(), rand)
  defp posting_date(:business, _index, rand), do: Random.pick(Dates.manual_days(), rand)
  defp posting_date(:saturday, _index, rand), do: Random.pick(Dates.saturdays(), rand)
  defp posting_date(:month_end, month, rand), do: {Dates.month_end(month), rand}
  defp posting_date({:day, day}, month, rand), do: {Dates.in_month(month, day), rand}

  defp posting_date(:rent_day, month, rand) do
    {month |> Dates.in_month(25) |> Dates.next_business_day(), rand}
  end

  defp posting_date(:period_end, index, rand) do
    {Enum.at(Dates.period_end_days(), rem(index - 1, 3)), rand}
  end

  defp header(%{source: :manual} = pattern, posting_date, rand) do
    {preparer, rand} = Random.pick(Catalog.preparers(), rand)
    {approver, rand} = approver(pattern.approval, rand)
    {seconds, rand} = between(@business_hours, rand)
    {gap, rand} = Random.integer(0, @manual_document_gap, rand)

    {%{
       source: "manual",
       entered_by: preparer,
       approved_by: approver,
       posting_date: posting_date,
       document_date: Date.add(posting_date, -gap),
       entered_at: Dates.at(posting_date, seconds),
       fiscal_period: posting_date.month
     }, rand}
  end

  defp header(%{source: :system}, posting_date, rand) do
    {seconds, rand} = between(@batch_hours, rand)
    {gap, rand} = Random.integer(0, @system_document_gap, rand)

    {%{
       source: "system",
       entered_by: Catalog.system_user(),
       approved_by: "",
       posting_date: posting_date,
       document_date: Date.add(posting_date, -gap),
       entered_at: Dates.at(posting_date, seconds),
       fiscal_period: posting_date.month
     }, rand}
  end

  # 승인자(mgr01, mgr02)와 입력자(acct01-acct05)는 겹치지 않으므로 자기승인이 생기지 않는다.
  defp approver(:required, rand), do: Random.pick(Catalog.approvers(), rand)

  defp approver(:optional, rand) do
    case Random.integer(0, 1, rand) do
      {0, rand} -> {"", rand}
      {1, rand} -> Random.pick(Catalog.approvers(), rand)
    end
  end

  defp between({min, max}, rand), do: Random.integer(min, max, rand)

  defp counterparty(:none, rand), do: {"", rand}
  defp counterparty(:customer, rand), do: Random.pick(Catalog.customers(), rand)
  defp counterparty(:vendor, rand), do: Random.pick(Catalog.vendors(), rand)
  defp counterparty({:fixed, code}, rand), do: {code, rand}

  defp description(%{days: days} = pattern, posting_date)
       when days in @monthly_days or is_tuple(days) do
    "#{posting_date.month}월 #{pattern.description}"
  end

  defp description(pattern, _posting_date), do: pattern.description

  # 같은 거래처, 금액, 계정 구성이 이미 있으면 금액을 다시 뽑는다 (도메인 문서 7.3).
  # B1 처럼 금액이 고정이면 다시 뽑아도 같으므로 그대로 둔다. 매월 25일 전후라 7일 윈도 밖이다.
  defp put_lines(entry, pattern, gen) do
    {amount, rand} = draw_amount(pattern, gen.rand)
    entry = %{entry | lines: lines(pattern.kind, amount)}

    case Entry.claim_duplicate_key(gen.dup_keys, entry) do
      {:ok, keys} -> {entry, %{gen | rand: rand, dup_keys: keys}}
      :taken when pattern.min == pattern.max -> {entry, %{gen | rand: rand}}
      :taken -> put_lines(entry, pattern, %{gen | rand: rand})
    end
  end

  defp draw_amount(pattern, rand) do
    {units, rand} =
      Random.integer(div(pattern.min, pattern.step), div(pattern.max, pattern.step), rand)

    {avoid_round(units * pattern.step, pattern), rand}
  end

  # 수기 전표가 10,000,000원 이상이고 1,000,000의 배수면 한 단위 옮긴다 (도메인 문서 7.3).
  # 라운드 금액이 의도인 패턴(step 이 1,000,000)은 건드리지 않는다.
  defp avoid_round(amount, %{source: :manual, step: step, max: max})
       when step < @round_unit and amount >= @round_min_amount and rem(amount, @round_unit) == 0 do
    if amount + step <= max, do: amount + step, else: amount - step
  end

  defp avoid_round(amount, _pattern), do: amount

  defp lines({debit, credit}, amount), do: [{debit, :debit, amount}, {credit, :credit, amount}]

  defp lines(:vat_sale, supply) do
    tax = div(supply, 10)
    [{"1110", :debit, supply + tax}, {"4110", :credit, supply}, {"2150", :credit, tax}]
  end

  defp lines(:vat_purchase, supply) do
    tax = div(supply, 10)
    [{"1220", :debit, supply}, {"1330", :debit, tax}, {"2110", :credit, supply + tax}]
  end

  defp lines(:payroll, gross) do
    withheld = div(gross, 10)
    [{"5210", :debit, gross}, {"1020", :credit, gross - withheld}, {"2140", :credit, withheld}]
  end
end
