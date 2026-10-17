defmodule Tickmark.LedgerFixtures do
  @moduledoc """
  Small GL CSV files for the ledger tests. Values are synthetic only.

  Rows are maps keyed by column atoms. `gl_csv/2` turns them into CSV text and
  `write_csv!/1` puts the text in a temporary file that is removed when the
  test ends.
  """
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Tickmark.Ledger.CsvParser

  @doc "One CSV row with synthetic defaults. Values are strings, as in a file."
  def gl_row(attrs \\ %{}) do
    Enum.into(attrs, %{
      entry_number: "JE-0001",
      line_number: "1",
      posting_date: "2025-03-31",
      document_date: "2025-03-31",
      entered_at: "2025-03-31 10:00:00",
      fiscal_year: "2025",
      fiscal_period: "3",
      account_code: "51100",
      account_name: "복리후생비",
      debit: "1000000",
      credit: "",
      description: "합성 거래",
      counterparty: "합성거래처",
      entered_by: "user01",
      approved_by: "user02",
      source: "manual"
    })
  end

  @doc """
  A balanced two-line entry: a debit line and a credit line of `amount`.
  `attrs` apply to both lines (header fields, for example).
  """
  def gl_entry(entry_number, amount \\ "1000000", attrs \\ %{}) do
    common = Map.merge(%{entry_number: entry_number}, Map.new(attrs))

    [
      gl_row(Map.merge(%{line_number: "1", debit: amount, credit: ""}, common)),
      gl_row(
        Map.merge(
          %{
            line_number: "2",
            account_code: "10300",
            account_name: "보통예금",
            debit: "",
            credit: amount
          },
          common
        )
      )
    ]
  end

  @doc """
  CSV text for `rows`. A row is a column map or a raw line written as is.

  Options:

    * `:columns` - header names in file order (default: the contract order)
    * `:newline` - line ending (default `"\\n"`)
  """
  def gl_csv(rows, opts \\ []) do
    columns = Keyword.get(opts, :columns, CsvParser.column_names())
    newline = Keyword.get(opts, :newline, "\n")

    lines =
      Enum.map(rows, fn
        row when is_binary(row) -> row
        row when is_map(row) -> encode_row(row, columns)
      end)

    Enum.map_join([Enum.join(columns, ",") | lines], "", &(&1 <> newline))
  end

  @doc "Writes `content` to a temporary file removed after the test. Returns the path."
  def write_csv!(content) do
    path = Path.join(System.tmp_dir!(), "tickmark-test-#{System.unique_integer([:positive])}.csv")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp encode_row(row, columns) do
    row = Map.new(row, fn {column, value} -> {to_string(column), value} end)

    Enum.map_join(columns, ",", fn name ->
      row |> Map.get(name, "") |> to_string() |> encode_cell()
    end)
  end

  defp encode_cell(value) do
    if String.contains?(value, [",", "\"", "\n", "\r"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end
end
