defmodule Tickmark.Ledger.Generator do
  @moduledoc """
  결정적 합성 GL 생성기 (도메인 문서 7장, 설계 문서 2.1 계약).

  순수 함수다. DB, Repo, 파일 쓰기가 없다. 같은 seed 는 같은 바이트를 만든다.

  ## 출력

  - `gl_csv`: MVP 문서 5장 16개 컬럼. UTF-8(BOM 없음), `NimbleCSV.RFC4180`(줄 끝 CRLF).
    금액은 원 단위 정수 문자열, 없는 쪽은 `"0"`. 날짜는 `YYYY-MM-DD`, `entered_at` 은
    `YYYY-MM-DD HH:MM:SS`(KST, 오프셋 없음). 전표번호는 `JE2025-000001` 형식이고
    (전기일, 입력일시, 생성 순서) 오름차순으로 매긴다. 한 전표의 행은 연속이다.
  - `labels_csv`: 도메인 문서 7.6 필드 `entry_number, label, scenario_id, expected_rules,
    expected_score, expected_triage, probe`. 전표마다 1행이다. `expected_rules` 는 rule_id 를
    알파벳순으로 정렬해 `;` 로 잇고 clean 은 빈 칸이다. `expected_triage`, `probe` 는 `true`/`false`.
    정답 라벨은 GL CSV 에 섞지 않는다.

  ## 결정성

  난수 상태(`:rand` 상태)를 프로세스 사전에 두지 않고 함수 사이에 명시적으로 넘긴다
  (`Tickmark.Ledger.Generator.Random`). `Enum.shuffle/1`, `Enum.random/1`, 현재 시각, 큰 맵의 순회
  순서는 쓰지 않는다. 정상 패턴은 쿼터를 정확히 채우고, 변이 대상은 후보를 시드로 섞어 앞에서 k 건을 취한다.

  ## 명세 해석 (확인 필요)

  - N01, N03 금액 범위는 공급가액 기준이고 부가세 10%를 더해 차변/대변 합계를 만든다.
  - N05 급여는 총급여의 10%를 예수금(2140)으로, 나머지를 보통예금으로 지급한다.
  - 금액 단위는 10원이다. 라운드 금액이 의도인 B1, B4 만 1,000,000원 단위다.
  - B1-B4 는 정상 패턴 쿼터와 별도로 추가한다. B2 금액은 500,000-15,000,000원, B3 는
    100,000-20,000,000원으로 가정했다. B1 거래처는 V030, 전기일은 매월 25일(영업일이 아니면 다음
    영업일)이다. B4 는 거래처가 없다.
  - N12 승인자 공란은 절반 확률이다. N21 은 매월 10일에 전기한다. 자동 전표는 2025년 아무 날에나 전기한다.
  - I1, C1 의 휴일표 날짜는 평일 공휴일 17일 중에서 고른다(주말과 겹치는 공휴일 제외).
    C1 은 주말 4건, 평일 공휴일 4건이고 입력 시각은 22-24시와 0-6시를 번갈아 쓴다.
  - C2 는 12-29 ~ 12-31 순환, 기간 12, 승인자 = 입력자. C4 는 증빙일 31-90일 이전, 승인자 공란.
    C3 는 12-29, 12-30 전기, 기간 12.
  - 변이로 전기일이 바뀌면 회계기간은 새 전기일의 월이다(I4 의 기간 13 은 예외).
    증빙일은 2024년이나 2026년이 될 수 있다.
  - 거래처 열에는 코드(C001, V001)만 쓴다.
  - 중복 키(거래처, 금액, 계정 구성)는 날짜와 상관없이 전체에서 겹치지 않게 등록한다. I8 복제본과
    B1(월 1회, 7일 윈도 밖)만 예외다.
  - `target_lines` 인자는 구현하지 않았다. 계약(설계 문서 2.1)의 opts 는 `seed` 뿐이다.
  """

  alias Tickmark.Ledger.Generator.{Builder, Catalog, Csv, Random, Scenarios}

  @default_seed 20_251_231

  @spec default_seed() :: integer()
  def default_seed, do: @default_seed

  @spec generate(keyword()) :: %{
          gl_csv: binary(),
          labels_csv: binary(),
          entry_count: pos_integer(),
          line_count: pos_integer()
        }
  def generate(opts \\ []) do
    opts = Keyword.validate!(opts, seed: @default_seed)
    gen = %{rand: Random.new(opts[:seed]), dup_keys: MapSet.new(), next_id: 1}

    {normal, gen} = Builder.build_all(Catalog.normal_patterns(), gen)
    {benign, gen} = Builder.build_all(Catalog.benign_patterns(), gen)
    {injected, _gen} = Scenarios.inject(normal, gen)

    entries = number(injected ++ benign)

    %{
      gl_csv: Csv.gl(entries),
      labels_csv: Csv.labels(entries),
      entry_count: length(entries),
      line_count: Enum.sum_by(entries, &length(&1.lines))
    }
  end

  defp number(entries) do
    entries
    |> Enum.sort_by(fn entry ->
      {Date.to_gregorian_days(entry.posting_date),
       NaiveDateTime.to_gregorian_seconds(entry.entered_at), entry.id}
    end)
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, n} ->
      Map.put(entry, :number, "JE2025-" <> String.pad_leading(Integer.to_string(n), 6, "0"))
    end)
  end
end
