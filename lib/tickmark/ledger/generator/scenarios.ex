defmodule Tickmark.Ledger.Generator.Scenarios do
  @moduledoc """
  이상 전표 주입 (도메인 문서 7.4).

  - I1-I6, C1, C2, C4: 정상 전표(clean base)를 제자리에서 변이한다. 후보 목록을 시드로 섞고 앞에서
    k 건을 취한다. 앞 시나리오가 쓴 전표는 다시 고르지 않는다.
  - I7, C3: 희귀 쌍 전표를 새로 만든다. I8: clean base 를 복제해 새 전표로 추가한다.
  - 프로브: C2, C4 변이 결과 중 5건의 적요를 지시문으로 바꾼다. 룰 기대값은 그대로다.
  """

  alias Tickmark.Ledger.Generator.{Builder, Catalog, Dates, Entry, Random}

  # {시나리오, 건수, 후보 조건}. 위에서부터 차례로 적용한다.
  @mutations [
    {"I1", 30, :manual},
    {"I2", 30, :manual},
    {"I3", 30, :manual_approved},
    {"I4", 25, :manual},
    {"I5", 30, :manual_over_approval_min},
    {"I6", 25, :any},
    {"C1", 8, :manual},
    {"C2", 6, :manual},
    {"C4", 4, :manual}
  ]

  # 22:00:00 - 23:59:59, 00:00:00 - 05:59:59 (자정 이후 초)
  @late_night {79_200, 86_399}
  @early_morning {0, 21_599}

  # 도메인 문서 2.6 approval_min_amount, 2.9 duplicate_window_days
  @approval_min_amount 1_000_000
  @duplicate_window_days 7

  @duplicate_count 15
  @probe_count 5
  @probe_scenarios ["C2", "C4"]

  @doc "정상 전표 목록을 받아 변이한 목록에 새 이상 전표(I7, I8, C3)를 붙여 돌려준다."
  def inject(clean, gen) do
    {mutated, used, gen} =
      Enum.reduce(@mutations, {[], MapSet.new(), gen}, fn mutation, acc ->
        mutate_batch(mutation, clean, acc)
      end)

    {mutated, gen} = mark_probes(mutated, gen)
    {copies, gen} = duplicate_copies(clean, used, gen)
    {rare, gen} = Builder.build_all(Catalog.rare_patterns(), gen)
    {composite, gen} = Builder.build_all(Catalog.composite_rare_patterns(), gen)

    {composite, gen} =
      composite
      |> Enum.with_index()
      |> Enum.map_reduce(gen, fn {entry, position}, gen ->
        enter_between(entry, off_hours(position), gen)
      end)

    # 변이한 전표를 id 로 찾아 원래 자리에 넣는다. 맵은 조회에만 쓰고 순회하지 않는다.
    replaced = Map.new(mutated, &{&1.id, &1})
    entries = Enum.map(clean, &Map.get(replaced, &1.id, &1))

    {entries ++ copies ++ rare ++ composite, gen}
  end

  defp mutate_batch({scenario, count, filter}, clean, {mutated, used, gen}) do
    candidates = Enum.filter(clean, &(candidate?(&1, filter) and not MapSet.member?(used, &1.id)))
    {shuffled, rand} = Random.shuffle(candidates, gen.rand)
    chosen = Enum.take(shuffled, count)

    {changed, gen} =
      chosen
      |> Enum.with_index()
      |> Enum.map_reduce(%{gen | rand: rand}, fn {entry, position}, gen ->
        mutate(scenario, entry, position, gen)
      end)

    rules = Catalog.scenario_rules(scenario)
    labeled = Enum.map(changed, &Entry.label(&1, :anomaly, scenario, rules))
    used = Enum.reduce(chosen, used, &MapSet.put(&2, &1.id))

    {mutated ++ labeled, used, gen}
  end

  defp candidate?(_entry, :any), do: true
  defp candidate?(entry, :manual), do: entry.source == "manual"

  defp candidate?(entry, :manual_approved),
    do: entry.source == "manual" and entry.approved_by != ""

  defp candidate?(entry, :manual_over_approval_min) do
    entry.source == "manual" and Entry.amount(entry) >= @approval_min_amount
  end

  # position 은 섞은 뒤 순서(0부터). 건수 배분(주말 20 / 휴일 10 등)에 쓴다.
  defp mutate("I1", entry, position, gen) when position < 20,
    do: move_to(entry, Dates.weekend_days(), gen)

  defp mutate("I1", entry, _position, gen), do: move_to(entry, Dates.weekday_holidays(), gen)

  defp mutate("I2", entry, position, gen) when position < 15,
    do: enter_between(entry, @late_night, gen)

  defp mutate("I2", entry, _position, gen), do: enter_between(entry, @early_morning, gen)

  defp mutate("I3", entry, _position, gen), do: to_round_amount(entry, gen)

  defp mutate("I4", entry, position, gen) when position < 17 do
    {Entry.move_posting(entry, period_end_day(position)), gen}
  end

  defp mutate("I4", entry, _position, gen) do
    {%{Entry.move_posting(entry, Dates.closing_date()) | fiscal_period: 13}, gen}
  end

  defp mutate("I5", entry, position, gen) when position < 15,
    do: {%{entry | approved_by: ""}, gen}

  defp mutate("I5", entry, _position, gen), do: {%{entry | approved_by: entry.entered_by}, gen}

  defp mutate("I6", entry, position, gen) when position < 18,
    do: shift_document(entry, -90, -31, gen)

  defp mutate("I6", entry, _position, gen), do: shift_document(entry, 1, 15, gen)

  defp mutate("C1", entry, position, gen) do
    days = if position < 4, do: Dates.weekend_days(), else: Dates.weekday_holidays()
    {entry, gen} = move_to(entry, days, gen)
    enter_between(entry, off_hours(position), gen)
  end

  defp mutate("C2", entry, position, gen) do
    entry = Entry.move_posting(entry, period_end_day(position))
    {entry, gen} = to_round_amount(entry, gen)
    {%{entry | approved_by: entry.entered_by}, gen}
  end

  defp mutate("C4", entry, _position, gen) do
    {entry, gen} = shift_document(entry, -90, -31, gen)
    {entry, gen} = to_round_amount(entry, gen)
    {%{entry | approved_by: ""}, gen}
  end

  defp move_to(entry, days, gen) do
    {date, rand} = Random.pick(days, gen.rand)
    {Entry.move_posting(entry, date), %{gen | rand: rand}}
  end

  defp enter_between(entry, {min, max}, gen) do
    {seconds, rand} = Random.integer(min, max, gen.rand)
    {Entry.put_entered_time(entry, seconds), %{gen | rand: rand}}
  end

  # 증빙일 = 전기일 + offset. 음수면 소급(전기일이 늦음), 양수면 선기표.
  defp shift_document(entry, min, max, gen) do
    {offset, rand} = Random.integer(min, max, gen.rand)
    {%{entry | document_date: Date.add(entry.posting_date, offset)}, %{gen | rand: rand}}
  end

  # 10,000,000-90,000,000 의 1,000,000 배수. 다른 전표와 중복 키가 겹치면 다시 뽑는다.
  defp to_round_amount(entry, gen) do
    {millions, rand} = Random.integer(10, 90, gen.rand)
    rounded = Entry.put_amount(entry, millions * 1_000_000)

    case Entry.claim_duplicate_key(gen.dup_keys, rounded) do
      {:ok, keys} -> {rounded, %{gen | rand: rand, dup_keys: keys}}
      :taken -> to_round_amount(entry, %{gen | rand: rand})
    end
  end

  defp period_end_day(position), do: Enum.at(Dates.period_end_days(), rem(position, 3))

  defp off_hours(position) when rem(position, 2) == 0, do: @late_night
  defp off_hours(_position), do: @early_morning

  defp mark_probes(mutated, gen) do
    {targets, rand} =
      mutated
      |> Enum.filter(&(&1.scenario in @probe_scenarios))
      |> Enum.map(& &1.id)
      |> Random.shuffle(gen.rand)

    texts = targets |> Enum.take(@probe_count) |> Enum.zip(Catalog.probe_texts()) |> Map.new()

    marked =
      Enum.map(mutated, fn entry ->
        case Map.fetch(texts, entry.id) do
          {:ok, text} -> %{entry | probe: true, description: text}
          :error -> entry
        end
      end)

    {marked, %{gen | rand: rand}}
  end

  # I8: 2-11월, 거래처 있음, 100만 원 이상, 아직 쓰지 않은 clean base 를 섞어 앞에서부터 복제한다.
  defp duplicate_copies(clean, used, gen) do
    candidates =
      Enum.filter(clean, fn entry ->
        entry.posting_date.month in 2..11 and Entry.duplicate_key(entry) != nil and
          not MapSet.member?(used, entry.id)
      end)

    {shuffled, rand} = Random.shuffle(candidates, gen.rand)

    {copies, gen} =
      Enum.reduce_while(shuffled, {[], %{gen | rand: rand}}, fn base, {copies, gen} ->
        {copy, gen} = copy_one(base, gen)
        copies = if copy, do: [copy | copies], else: copies

        if length(copies) == @duplicate_count,
          do: {:halt, {copies, gen}},
          else: {:cont, {copies, gen}}
      end)

    {Enum.reverse(copies), gen}
  end

  # 전기일 +1-5영업일. 연휴로 달력일 차이가 7일을 넘으면 그 후보는 건너뛴다 (nil).
  defp copy_one(base, gen) do
    {days, rand} = Random.integer(1, 5, gen.rand)
    gen = %{gen | rand: rand}
    date = Dates.add_business_days(base.posting_date, days)

    if Date.diff(date, base.posting_date) > @duplicate_window_days do
      {nil, gen}
    else
      copy =
        base
        |> Entry.move_posting(date)
        |> Map.put(:id, gen.next_id)
        |> Entry.label(:anomaly, "I8", Catalog.scenario_rules("I8"))

      {copy, %{gen | next_id: gen.next_id + 1}}
    end
  end
end
