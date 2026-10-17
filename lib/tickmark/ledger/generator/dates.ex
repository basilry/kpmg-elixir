defmodule Tickmark.Ledger.Generator.Dates do
  @moduledoc """
  2025 회계연도의 날짜 후보표. 컴파일할 때 한 번 계산해 튜플로 둔다.

  - 수기 영업일(`manual_days/0`): 휴일표(`Tickmark.Testing.Holidays`)에 없는 평일에서
    12-29 ~ 12-31 을 뺀 날. 12-29 ~ 12-31 은 기말 수기 룰 구간이다.
  - 영업일(`business_day?/1`): 휴일표에 없는 평일. I8 의 "+1-5영업일" 과 B1 임차료 지급일 계산에 쓴다.
  """

  alias Tickmark.Testing.Holidays

  @closing_date ~D[2025-12-31]
  @period_end_days [~D[2025-12-29], ~D[2025-12-30], ~D[2025-12-31]]
  @year_days Enum.to_list(Date.range(~D[2025-01-01], @closing_date))

  @any_days List.to_tuple(@year_days)
  @manual_days @year_days
               |> Enum.filter(&(Date.day_of_week(&1) <= 5 and not Holidays.holiday?(&1)))
               |> Enum.reject(&(&1 in @period_end_days))
               |> List.to_tuple()
  @weekend_days @year_days |> Enum.filter(&(Date.day_of_week(&1) >= 6)) |> List.to_tuple()
  @saturdays @year_days |> Enum.filter(&(Date.day_of_week(&1) == 6)) |> List.to_tuple()
  @weekday_holidays Holidays.all() |> Enum.filter(&(Date.day_of_week(&1) <= 5)) |> List.to_tuple()

  def closing_date, do: @closing_date
  def period_end_days, do: @period_end_days
  def any_days, do: @any_days
  def manual_days, do: @manual_days
  def weekend_days, do: @weekend_days
  def saturdays, do: @saturdays
  def weekday_holidays, do: @weekday_holidays

  @doc "2025년 month 월의 마지막 날 (달력상 월말)."
  def month_end(month), do: Date.end_of_month(Date.new!(2025, month, 1))

  def in_month(month, day), do: Date.new!(2025, month, day)

  def business_day?(date), do: Date.day_of_week(date) <= 5 and not Holidays.holiday?(date)

  @doc "date 가 영업일이면 그대로, 아니면 그다음 영업일."
  def next_business_day(date) do
    if business_day?(date), do: date, else: next_business_day(Date.add(date, 1))
  end

  @doc "date 다음 날부터 영업일을 n 개 센 날."
  def add_business_days(date, 0), do: date

  def add_business_days(date, n) when n > 0 do
    date |> Date.add(1) |> next_business_day() |> add_business_days(n - 1)
  end

  @doc "날짜와 자정 이후 초로 입력일시를 만든다."
  def at(date, seconds), do: NaiveDateTime.new!(date, Time.from_seconds_after_midnight(seconds))
end
