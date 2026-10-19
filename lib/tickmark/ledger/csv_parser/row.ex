defmodule Tickmark.Ledger.CsvParser.Row do
  @moduledoc """
  Turns the cells of one GL CSV row into typed values (planning doc 5,
  architecture doc 9.2 row checks). Checks that span rows live in
  `Tickmark.Ledger.CsvParser`.
  """

  @columns ~w(entry_number line_number posting_date document_date entered_at
              fiscal_year fiscal_period account_code account_name debit credit
              description counterparty entered_by approved_by source)a
  @optional_columns [:description, :counterparty, :approved_by]
  @amount_columns [:debit, :credit]

  @max_description_chars 500
  @max_cell_chars 200
  # numeric(18,2)
  @max_amount Decimal.new("9999999999999999.99")

  # Error codes from the architecture doc 9.2.
  @unreadable_code "parse_error"
  @too_long_code "too_long"
  @bad_value_code "invalid_value"

  @doc "The 16 contract columns, in the documented order."
  def columns, do: @columns

  @doc "The largest amount numeric(18,2) holds."
  def max_amount, do: @max_amount

  @doc """
  Parses one row. `indexes` are the cell positions of `columns/0`, in order.

  Returns the typed values keyed by column, or every cell error as
  `{column, code}` (`{nil, code}` for the row as a whole).
  """
  @spec parse([String.t()], [non_neg_integer()]) ::
          {:ok, %{atom() => term()}} | {:error, [{atom() | nil, String.t()}]}
  def parse(cells, indexes) when length(cells) == length(indexes) do
    cells = List.to_tuple(cells)
    values = Enum.map(indexes, &elem(cells, &1))

    {fields, errors} =
      @columns
      |> Enum.zip(values)
      |> Enum.reduce({%{}, []}, fn {column, raw}, {fields, errors} ->
        case parse_cell(column, raw) do
          {:ok, value} -> {Map.put(fields, column, value), errors}
          {:error, code} -> {fields, [{column, code} | errors]}
        end
      end)

    cond do
      errors != [] -> {:error, Enum.reverse(errors)}
      one_side?(fields) -> {:ok, fields}
      true -> {:error, [{nil, "both_sides"}]}
    end
  end

  def parse(_cells, _indexes), do: {:error, [{nil, @unreadable_code}]}

  defp one_side?(%{debit: debit, credit: credit}) do
    Decimal.gt?(debit, 0) != Decimal.gt?(credit, 0)
  end

  defp parse_cell(column, raw) do
    cond do
      not readable?(raw) -> {:error, @unreadable_code}
      too_long?(column, raw) -> {:error, @too_long_code}
      String.trim(raw) == "" -> blank_value(column)
      true -> parse_value(column, raw)
    end
  end

  # PostgreSQL text rejects invalid UTF-8 (for example a CP949 export) and NUL.
  defp readable?(raw), do: String.valid?(raw) and not String.contains?(raw, <<0>>)

  # varchar(n) counts code points, String.length/1 counts graphemes, so count
  # code points. Bytes are an upper bound, which skips the count for most cells.
  defp too_long?(column, raw) do
    limit = if column == :description, do: @max_description_chars, else: @max_cell_chars
    byte_size(raw) > limit and length(String.codepoints(raw)) > limit
  end

  defp blank_value(column) when column in @optional_columns, do: {:ok, nil}
  defp blank_value(column) when column in @amount_columns, do: {:ok, Decimal.new(0)}
  defp blank_value(_column), do: {:error, "required"}

  defp parse_value(:line_number, raw), do: parse_integer(raw, 1..999_999)
  defp parse_value(:fiscal_year, raw), do: parse_integer(raw, 1000..9999)
  defp parse_value(:fiscal_period, raw), do: parse_integer(raw, 1..13)
  defp parse_value(:posting_date, raw), do: parse_date(raw)
  defp parse_value(:document_date, raw), do: parse_date(raw)
  defp parse_value(:entered_at, raw), do: parse_datetime(raw)
  defp parse_value(column, raw) when column in @amount_columns, do: parse_amount(raw)
  defp parse_value(:source, "manual"), do: {:ok, :manual}
  defp parse_value(:source, "system"), do: {:ok, :system}
  defp parse_value(:source, _raw), do: {:error, @bad_value_code}
  # NimbleCSV fields are sub-binaries of the line. Kept strings are copied so
  # the line can be garbage collected.
  defp parse_value(_text_column, raw), do: {:ok, :binary.copy(raw)}

  # Plain ASCII digits only: no sign, space or underscore (String.to_integer/1
  # would accept "+1" and "-1"). Nine digits keep the value a small integer.
  defp parse_integer(raw, range) do
    with true <- byte_size(raw) <= 9 and digits?(raw),
         value = String.to_integer(raw),
         true <- value in range do
      {:ok, value}
    else
      _ -> {:error, "invalid_number"}
    end
  end

  defp parse_date(raw) do
    with 10 <- byte_size(raw),
         {:ok, date} <- Date.from_iso8601(raw) do
      {:ok, date}
    else
      _ -> {:error, "invalid_date"}
    end
  end

  # NaiveDateTime.from_iso8601/1 accepts and drops an offset ("+09:00", "Z"),
  # so the exact length of "YYYY-MM-DD HH:MM:SS" is checked first (V4).
  defp parse_datetime(raw) do
    with 19 <- byte_size(raw),
         {:ok, datetime} <- NaiveDateTime.from_iso8601(raw) do
      {:ok, datetime}
    else
      _ -> {:error, "invalid_date"}
    end
  end

  # Whole won only: "1000" or "1000.00". No sign, thousands separator or exponent.
  defp parse_amount(raw) do
    with true <- amount_format?(raw),
         {amount, ""} <- Decimal.parse(raw),
         true <- Decimal.integer?(amount),
         false <- Decimal.gt?(amount, @max_amount) do
      {:ok, amount}
    else
      _ -> {:error, "invalid_number"}
    end
  end

  defp amount_format?(raw) do
    case :binary.split(raw, ".") do
      [whole] -> digits?(whole)
      [whole, fraction] -> digits?(whole) and digits?(fraction)
    end
  end

  # Binary pattern matching instead of a regex: this runs for several cells of
  # every row.
  defp digits?(""), do: false
  defp digits?(raw), do: all_digits?(raw)

  defp all_digits?(<<char, rest::binary>>) when char in ?0..?9, do: all_digits?(rest)
  defp all_digits?(<<>>), do: true
  defp all_digits?(_other), do: false
end
