defmodule Tickmark.Ledger.Generator.Csv do
  @moduledoc """
  전표 목록을 GL CSV 와 라벨 CSV 바이너리로 바꾼다. `NimbleCSV.RFC4180` 으로 쓰므로 줄 끝은 CRLF 이다.
  각 전표에는 `Tickmark.Ledger.Generator` 가 붙인 `:number`(전표번호)가 있어야 한다.
  """

  alias NimbleCSV.RFC4180, as: CSV
  alias Tickmark.Ledger.Generator.Catalog

  # MVP 문서 5장 GL 계약 16개 컬럼 (순서 고정)
  @gl_header ~w(entry_number line_number posting_date document_date entered_at fiscal_year
                fiscal_period account_code account_name debit credit description counterparty
                entered_by approved_by source)

  # 도메인 문서 7.6 정답 라벨 필드
  @labels_header ~w(entry_number label scenario_id expected_rules expected_score expected_triage probe)

  def gl(entries) do
    rows =
      for entry <- entries,
          {{code, side, amount}, line_number} <- Enum.with_index(entry.lines, 1) do
        [
          entry.number,
          Integer.to_string(line_number),
          Date.to_iso8601(entry.posting_date),
          Date.to_iso8601(entry.document_date),
          NaiveDateTime.to_string(entry.entered_at),
          Integer.to_string(Catalog.fiscal_year()),
          Integer.to_string(entry.fiscal_period),
          code,
          Catalog.account_name(code),
          if(side == :debit, do: Integer.to_string(amount), else: "0"),
          if(side == :credit, do: Integer.to_string(amount), else: "0"),
          entry.description,
          entry.counterparty,
          entry.entered_by,
          entry.approved_by,
          entry.source
        ]
      end

    dump([@gl_header | rows])
  end

  @doc "expected_rules 는 rule_id 를 정렬해 `;` 로 잇는다 (없으면 빈 칸). 불리언은 true/false."
  def labels(entries) do
    rows =
      for entry <- entries do
        score = Catalog.score(entry.rules)

        [
          entry.number,
          Atom.to_string(entry.label),
          entry.scenario,
          entry.rules |> Enum.sort() |> Enum.join(";"),
          Integer.to_string(score),
          to_string(score >= Catalog.triage_threshold()),
          to_string(entry.probe)
        ]
      end

    dump([@labels_header | rows])
  end

  defp dump(rows), do: rows |> CSV.dump_to_iodata() |> IO.iodata_to_binary()
end
