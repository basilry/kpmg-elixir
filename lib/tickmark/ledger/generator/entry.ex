defmodule Tickmark.Ledger.Generator.Entry do
  @moduledoc """
  생성 중인 전표 한 건을 다루는 함수 모음. 전표는 CSV 로 쓰기 전의 맵이다.

  키: `id`(생성 순서), `scenario`, `label`, `rules`, `probe`, `posting_date`, `document_date`,
  `entered_at`, `fiscal_period`, `entered_by`, `approved_by`, `source`, `counterparty`, `description`,
  `lines`. `lines` 는 `[{계정 코드, :debit | :credit, 금액}]` 이다.
  """

  alias Tickmark.Ledger.Generator.Dates

  # 도메인 문서 2.9 duplicate_min_amount
  @duplicate_min_amount 1_000_000

  @doc "전표 금액 = 차변 합계 (= 대변 합계)."
  def amount(%{lines: lines}), do: Enum.sum(for {_code, :debit, amount} <- lines, do: amount)

  @doc "{(계정, 차대 구분)} 집합. 정렬해서 비교 가능한 목록으로 돌려준다."
  def signature(%{lines: lines}) do
    lines |> Enum.map(fn {code, side, _amount} -> {code, side} end) |> Enum.uniq() |> Enum.sort()
  end

  @doc "중복 전표 룰이 비교하는 키. 룰 대상이 아니면(거래처 공란, 100만 원 미만) nil."
  def duplicate_key(%{counterparty: ""}), do: nil

  def duplicate_key(entry) do
    amount = amount(entry)

    if amount >= @duplicate_min_amount,
      do: {entry.counterparty, amount, signature(entry)},
      else: nil
  end

  @doc """
  중복 키를 등록한다. 이미 있으면 `:taken`.
  날짜와 상관없이 키 자체를 겹치지 않게 하므로 7일 윈도보다 엄격하고, 날짜를 옮기는 변이 뒤에도 안전하다.
  """
  def claim_duplicate_key(keys, entry) do
    case duplicate_key(entry) do
      nil ->
        {:ok, keys}

      key ->
        if MapSet.member?(keys, key), do: :taken, else: {:ok, MapSet.put(keys, key)}
    end
  end

  @doc "전기일을 옮기고 증빙일과 입력일시도 같은 일수만큼 옮긴다. 회계기간은 새 전기일의 월."
  def move_posting(entry, date) do
    shift = Date.diff(date, entry.posting_date)

    %{
      entry
      | posting_date: date,
        document_date: Date.add(entry.document_date, shift),
        entered_at: NaiveDateTime.add(entry.entered_at, shift, :day),
        fiscal_period: date.month
    }
  end

  @doc "입력 날짜는 두고 시각만 바꾼다."
  def put_entered_time(entry, seconds) do
    %{entry | entered_at: Dates.at(NaiveDateTime.to_date(entry.entered_at), seconds)}
  end

  @doc "전표 금액을 total 로 바꾼다. 줄 금액은 차변, 대변 각각 비례로 나누고 나머지는 그 쪽 첫 줄에 더한다."
  def put_amount(entry, total) do
    old = amount(entry)
    lines = entry.lines |> scale_side(:debit, old, total) |> scale_side(:credit, old, total)
    %{entry | lines: lines}
  end

  defp scale_side(lines, side, old, new) do
    scaled =
      Enum.map(lines, fn
        {code, ^side, amount} -> {code, side, div(amount * new, old)}
        line -> line
      end)

    remainder = new - Enum.sum(for {_code, ^side, amount} <- scaled, do: amount)
    first = Enum.find_index(scaled, fn {_code, s, _amount} -> s == side end)
    List.update_at(scaled, first, fn {code, s, amount} -> {code, s, amount + remainder} end)
  end

  def label(entry, label, scenario, rules) do
    %{entry | label: label, scenario: scenario, rules: rules}
  end
end
