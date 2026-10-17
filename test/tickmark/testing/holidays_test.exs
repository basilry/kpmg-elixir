defmodule Tickmark.Testing.HolidaysTest do
  use ExUnit.Case, async: true

  alias Tickmark.Testing.Holidays

  test "2025년 표는 19일이고 오름차순이다" do
    dates = Holidays.all()

    assert length(dates) == 19
    assert dates == Enum.sort(dates, Date)
    assert Enum.all?(dates, &(&1.year == 2025))
    assert List.first(dates) == ~D[2025-01-01]
    assert List.last(dates) == ~D[2025-12-25]
  end

  test "임시공휴일과 대체공휴일이 들어 있고 모두 평일이다" do
    for date <- [~D[2025-01-27], ~D[2025-03-03], ~D[2025-05-06], ~D[2025-06-03], ~D[2025-10-08]] do
      assert Holidays.holiday?(date), "#{date} 가 휴일표에 없다"
      assert Date.day_of_week(date) <= 5, "#{date} 는 평일이어야 한다"
    end
  end

  test "주말과 겹치는 공휴일도 표에 남기고, 평일 공휴일은 17일이다" do
    assert Holidays.holiday?(~D[2025-03-01])
    assert Date.day_of_week(~D[2025-03-01]) == 6
    assert Holidays.holiday?(~D[2025-10-05])
    assert Date.day_of_week(~D[2025-10-05]) == 7

    weekday_holidays = Enum.filter(Holidays.all(), &(Date.day_of_week(&1) <= 5))
    assert length(weekday_holidays) == 17
  end

  test "근로자의 날, 연말 평일, 보통 평일은 휴일이 아니다" do
    for date <- [~D[2025-05-01], ~D[2025-12-29], ~D[2025-12-30], ~D[2025-12-31], ~D[2025-01-02]] do
      refute Holidays.holiday?(date), "#{date} 는 휴일이 아니어야 한다"
    end
  end

  test "다른 연도는 표가 없다" do
    refute Holidays.holiday?(~D[2026-01-01])
    refute Holidays.holiday?(~D[2024-12-25])
  end
end
