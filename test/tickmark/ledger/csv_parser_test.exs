defmodule Tickmark.Ledger.CsvParserTest do
  use ExUnit.Case, async: true
  use Oban.Testing, repo: Tickmark.Repo

  import Tickmark.LedgerFixtures

  alias Tickmark.Ledger.CsvParser

  # Collects entries in file order.
  defp parse(content) do
    case content |> write_csv!() |> CsvParser.parse([], &[&1 | &2]) do
      {:ok, entries, summary} -> {:ok, Enum.reverse(entries), summary}
      {:error, summary} -> {:error, summary}
    end
  end

  defp rejected(content) do
    assert {:error, summary} = parse(content)
    summary
  end

  defp error(line, field, code), do: %{"line" => line, "field" => field, "code" => code}

  defp codes(summary), do: Enum.map(summary.errors, & &1["code"])

  describe "valid files" do
    test "folds entries in file order and sums the file" do
      csv = gl_csv(gl_entry("JE-0001", "1000000") ++ gl_entry("JE-0002", "250000.00"))

      assert {:ok, [first, second], summary} = parse(csv)

      assert first.entry_number == "JE-0001"
      assert first.posting_date == ~D[2025-03-31]
      assert first.entered_at == ~N[2025-03-31 10:00:00]
      assert first.fiscal_year == 2025
      assert first.fiscal_period == 3
      assert first.source == :manual
      assert first.line_count == 2
      assert Decimal.equal?(first.total_debit, 1_000_000)
      assert Decimal.equal?(first.total_credit, 1_000_000)

      assert [debit_line, credit_line] = first.lines
      assert debit_line.line_number == 1
      assert debit_line.account_code == "51100"
      assert Decimal.equal?(debit_line.debit, 1_000_000)
      assert Decimal.equal?(debit_line.credit, 0)
      assert Decimal.equal?(credit_line.credit, 1_000_000)

      assert Decimal.equal?(second.total_debit, 250_000)

      assert summary.entry_count == 2
      assert summary.line_count == 4
      assert Decimal.equal?(summary.total_debit, 1_250_000)
      assert Decimal.equal?(summary.total_credit, 1_250_000)
      assert summary.errors == [] and summary.error_count == 0
      assert summary.warnings == [] and summary.warning_count == 0
    end

    test "turns blank optional cells into nil and blank amounts into zero" do
      csv =
        gl_csv(
          gl_entry("JE-0001", "5000", %{description: "", counterparty: " ", approved_by: ""})
        )

      assert {:ok, [entry], _summary} = parse(csv)
      assert entry.counterparty == nil
      assert entry.approved_by == nil
      assert Enum.all?(entry.lines, &is_nil(&1.description))
    end

    test "strips a UTF-8 BOM before the header" do
      csv = "﻿" <> gl_csv(gl_entry("JE-0001"))

      assert {:ok, [_entry], _summary} = parse(csv)
    end

    test "reads CRLF line endings" do
      csv = gl_csv(gl_entry("JE-0001"), newline: "\r\n")

      assert {:ok, [entry], _summary} = parse(csv)
      # source is the last column, so a leftover "\r" would make it invalid.
      assert entry.source == :manual
    end

    test "keeps a quoted comma and newline inside one cell" do
      [debit, credit] = gl_entry("JE-0001")

      csv =
        gl_csv(
          [%{debit | description: "식대, 회의\n2차"}, credit] ++
            [gl_row(%{entry_number: "JE-0002", debit: "x"})]
        )

      assert {:error, summary} = parse(csv)
      # The quoted newline does not count as a row: JE-0002 is the 4th record.
      assert error(4, "debit", "invalid_number") in summary.errors

      assert {:ok, [entry], _summary} =
               parse(gl_csv([%{debit | description: "식대, 회의\n2차"}, credit]))

      assert hd(entry.lines).description == "식대, 회의\n2차"
    end

    test "maps columns by name, whatever the header order" do
      rows = gl_entry("JE-0001", "7000")
      reversed = Enum.reverse(CsvParser.column_names())

      assert {:ok, [entry], _summary} = parse(gl_csv(rows, columns: reversed))
      assert {:ok, [^entry], _summary} = parse(gl_csv(rows))
    end

    test "skips blank lines" do
      csv = gl_csv(gl_entry("JE-0001") ++ ["", ",,,,,,,,,,,,,,,"] ++ gl_entry("JE-0002"))

      assert {:ok, [_, _], summary} = parse(csv)
      assert summary.entry_count == 2
    end

    test "accepts a file with a header and no rows" do
      assert {:ok, [], %{entry_count: 0, error_count: 0}} = parse(gl_csv([]))
    end
  end

  describe "period_mismatch warning" do
    test "is recorded on the first line of the entry and does not block the load" do
      csv =
        gl_csv(
          gl_entry("JE-0001") ++
            gl_entry("JE-0002", "1000", %{posting_date: "2025-04-01"}) ++
            gl_entry("JE-0003", "1000", %{posting_date: "2025-12-31", fiscal_period: "13"})
        )

      assert {:ok, [_, _, _], summary} = parse(csv)
      assert summary.warnings == [error(4, "fiscal_period", "period_mismatch")]
      assert summary.warning_count == 1
    end
  end

  describe "error codes" do
    test "missing_column names each missing header" do
      columns = CsvParser.column_names() -- ["approved_by", "source"]
      summary = rejected(gl_csv(gl_entry("JE-0001"), columns: columns))

      assert summary.errors == [
               error(1, "approved_by", "missing_column"),
               error(1, "source", "missing_column")
             ]
    end

    test "missing_column for every column of an empty file" do
      summary = rejected("")

      assert summary.error_count == 16
      assert Enum.uniq(codes(summary)) == ["missing_column"]
    end

    test "required for a blank required cell" do
      [debit, credit] = gl_entry("JE-0001")
      summary = rejected(gl_csv([%{debit | account_code: "  "}, credit]))

      assert summary.errors == [error(2, "account_code", "required")]
    end

    test "invalid_date for a wrong date or a date time with an offset" do
      [debit, credit] = gl_entry("JE-0001")

      assert rejected(gl_csv([%{debit | document_date: "2025/03/31"}, credit])).errors ==
               [error(2, "document_date", "invalid_date")]

      for entered_at <- ["2025-03-31T10:00:00+09:00", "2025-03-31 10:00:00Z", "2025-03-31"] do
        rows = gl_entry("JE-0001", "1000", %{entered_at: entered_at})

        assert rejected(gl_csv(rows)).errors == [
                 error(2, "entered_at", "invalid_date"),
                 error(3, "entered_at", "invalid_date")
               ]
      end
    end

    test "invalid_number for amounts that are not whole won and out of range integers" do
      for amount <- ["1,000", "1000.50", "-1000", "1e3", " 1000", "12345678901234567"] do
        [debit, credit] = gl_entry("JE-0001")

        assert rejected(gl_csv([%{debit | debit: amount}, credit])).errors ==
                 [error(2, "debit", "invalid_number")],
               "accepted #{inspect(amount)}"
      end

      [debit, credit] = gl_entry("JE-0001")

      assert rejected(gl_csv([%{debit | fiscal_period: "14"}, %{credit | fiscal_period: "14"}])).errors ==
               [
                 error(2, "fiscal_period", "invalid_number"),
                 error(3, "fiscal_period", "invalid_number")
               ]
    end

    test "duplicate_line_number when a line number repeats in an entry" do
      [debit, credit] = gl_entry("JE-0001")

      assert rejected(gl_csv([debit, %{credit | line_number: "1"}])).errors ==
               [error(3, "line_number", "duplicate_line_number")]
    end

    test "both_sides when a line has both or neither side" do
      [debit, credit] = gl_entry("JE-0001")

      assert rejected(gl_csv([%{debit | credit: "1000000"}, credit])).errors ==
               [error(2, nil, "both_sides")]

      assert rejected(gl_csv([%{debit | debit: "0"}, credit])).errors ==
               [error(2, nil, "both_sides")]
    end

    test "unbalanced_entry on the first line of the entry" do
      [debit, credit] = gl_entry("JE-0001")

      assert rejected(gl_csv([debit, %{credit | credit: "999999"}])).errors ==
               [error(2, nil, "unbalanced_entry")]
    end

    test "inconsistent_header on each line that differs from the first" do
      [debit, credit] = gl_entry("JE-0001")

      summary =
        rejected(gl_csv([debit, %{credit | posting_date: "2025-03-30", entered_by: "user09"}]))

      assert summary.errors == [
               error(3, "posting_date", "inconsistent_header"),
               error(3, "entered_by", "inconsistent_header")
             ]
    end

    test "non_contiguous_entry when an entry number comes back" do
      csv = gl_csv(gl_entry("JE-0001") ++ gl_entry("JE-0002") ++ gl_entry("JE-0001"))

      assert rejected(csv).errors == [error(6, "entry_number", "non_contiguous_entry")]
    end

    test "too_many_rows at the first data row past 100,000" do
      # One-cell rows with the same entry number are grouped into one entry,
      # and the limit is checked before any row is parsed, so this stays fast.
      # At the limit every row is parsed and fails on its cell count alone.
      at_limit = rejected(gl_csv(List.duplicate("x", 100_000)))
      assert at_limit.error_count == 100_000
      assert Enum.uniq(codes(at_limit)) == ["parse_error"]

      over = rejected(gl_csv(List.duplicate("x", 100_001)))
      assert over.errors == [error(100_002, nil, "too_many_rows")]
      assert over.error_count == 1
    end

    test "parse_error for broken quoting, with the row it stopped at" do
      csv = gl_csv(gl_entry("JE-0001") ++ ["JE-0002,\"broken"])

      assert rejected(csv).errors == [error(4, nil, "parse_error")]
    end

    test "unknown_column for an unknown or duplicated header, without echoing it" do
      columns = CsvParser.column_names() ++ ["memo"]

      assert rejected(gl_csv(gl_entry("JE-0001"), columns: columns)).errors == [
               error(1, nil, "unknown_column")
             ]

      columns = CsvParser.column_names() ++ ["debit"]

      assert rejected(gl_csv(gl_entry("JE-0001"), columns: columns)).errors == [
               error(1, nil, "unknown_column")
             ]
    end

    test "parse_error for a row with the wrong number of cells" do
      csv = gl_csv(gl_entry("JE-0001") ++ ["JE-0002,1,2025-03-31"])

      assert rejected(csv).errors == [error(4, nil, "parse_error")]
    end

    test "parse_error, invalid_value and too_long for bad cells" do
      [debit, credit] = gl_entry("JE-0001")

      for {column, value, code} <- [
            {:account_name, <<0xB0, 0xA1>>, "parse_error"},
            {:account_name, "a" <> <<0>>, "parse_error"},
            {:source, "batch", "invalid_value"},
            {:account_name, String.duplicate("가", 201), "too_long"},
            {:description, String.duplicate("가", 501), "too_long"}
          ] do
        assert rejected(gl_csv([Map.put(debit, column, value), credit])).errors ==
                 [error(2, to_string(column), code)],
               "accepted #{column}"
      end

      assert {:ok, _, _} =
               parse(gl_csv([%{debit | description: String.duplicate("가", 500)}, credit]))
    end
  end

  describe "error collection" do
    test "keeps at most 100 errors and counts all of them" do
      rows =
        Enum.flat_map(1..150, fn n ->
          [debit, credit] = gl_entry("JE-#{n}")
          [debit, %{credit | credit: "1"}]
        end)

      summary = rejected(gl_csv(rows))

      assert length(summary.errors) == 100
      assert summary.error_count == 150
      assert hd(summary.errors) == error(2, nil, "unbalanced_entry")
    end

    test "stops handing entries to the caller after the first error" do
      [debit, credit] = gl_entry("JE-0002")
      csv = gl_csv(gl_entry("JE-0001") ++ [debit, %{credit | credit: "1"}] ++ gl_entry("JE-0003"))
      path = write_csv!(csv)

      assert {:error, summary} =
               CsvParser.parse(path, nil, fn entry, acc ->
                 send(self(), {:entry, entry.entry_number})
                 acc
               end)

      assert summary.error_count == 1
      assert_received {:entry, "JE-0001"}
      refute_received {:entry, _}
    end
  end
end
