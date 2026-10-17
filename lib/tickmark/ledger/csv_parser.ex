defmodule Tickmark.Ledger.CsvParser do
  @moduledoc """
  Reads a GL CSV (planning doc 5) and validates it one journal entry at a time
  (architecture doc 9.2). It does not touch the database.

  `parse/3` streams the file, groups consecutive rows by `entry_number`, and
  calls `fun` once per valid entry while no error has been found. After the
  first error it keeps validating, to report more errors in one go, but stops
  calling `fun`. The caller runs inside a transaction and rolls back on
  `{:error, summary}`.

  Row numbers in errors and warnings are CSV record numbers with the header as
  row 1, which is what a spreadsheet shows. A quoted cell that spans several
  physical lines is still one row. `"field"` is always a contract column name
  or nil, never a value from the file.
  """

  require Logger

  alias Tickmark.Ledger.CsvParser.Row

  @column_names Enum.map(Row.columns(), &Atom.to_string/1)

  # V1: every line of an entry must carry the same values in these columns.
  @header_columns [
    :posting_date,
    :document_date,
    :entered_at,
    :fiscal_year,
    :fiscal_period,
    :entered_by,
    :approved_by,
    :source,
    :counterparty
  ]

  # Per-line columns. Everything else belongs to the entry header.
  @line_columns [:line_number, :account_code, :account_name, :debit, :credit, :description]

  @max_rows 100_000
  @max_kept 100
  # Longer than any valid row (16 cells, 500 + 15 x 200 chars, 4 bytes each,
  # quotes doubled), so it only stops files built to exhaust memory.
  @max_line_bytes 65_536

  # A file NimbleCSV cannot read, and a header with an unknown or duplicated
  # name. The 9.2 list has no closer code (see the devlog).
  @unreadable_code "parse_error"

  @type error :: %{String.t() => term()}

  @type line :: %{
          line_number: pos_integer(),
          account_code: String.t(),
          account_name: String.t(),
          debit: Decimal.t(),
          credit: Decimal.t(),
          description: String.t() | nil
        }

  @type entry :: %{
          entry_number: String.t(),
          posting_date: Date.t(),
          document_date: Date.t(),
          entered_at: NaiveDateTime.t(),
          fiscal_year: integer(),
          fiscal_period: 1..13,
          entered_by: String.t(),
          approved_by: String.t() | nil,
          counterparty: String.t() | nil,
          source: :manual | :system,
          line_count: pos_integer(),
          total_debit: Decimal.t(),
          total_credit: Decimal.t(),
          lines: [line()]
        }

  @type summary :: %{
          entry_count: non_neg_integer(),
          line_count: non_neg_integer(),
          total_debit: Decimal.t(),
          total_credit: Decimal.t(),
          errors: [error()],
          error_count: non_neg_integer(),
          warnings: [error()],
          warning_count: non_neg_integer()
        }

  @doc "The 16 header names of the GL CSV contract, in the documented order."
  @spec column_names() :: [String.t()]
  def column_names, do: @column_names

  @doc """
  Folds `fun` over the valid entries of the CSV at `path`.

  Returns `{:ok, acc, summary}` when the whole file is valid, otherwise
  `{:error, summary}` with at most #{@max_kept} errors and the total count.
  """
  @spec parse(Path.t(), acc, (entry(), acc -> acc)) :: {:ok, acc, summary()} | {:error, summary()}
        when acc: term()
  def parse(path, acc, fun) when is_function(fun, 2) do
    # An exception throws away the reduce accumulator, so the last row number
    # that came out of the parser is kept outside it.
    last_row = :counters.new(1, [])

    try do
      path
      |> records(last_row)
      |> parse_records(acc, fun)
    rescue
      error in NimbleCSV.ParseError ->
        unreadable_file(last_row, error.__struct__)
    catch
      :throw, :line_too_long ->
        unreadable_file(last_row, :line_too_long)
    end
  end

  defp records(path, last_row) do
    path
    |> File.stream!([:trim_bom])
    |> Stream.each(&check_line_length!/1)
    |> NimbleCSV.RFC4180.parse_stream(skip_headers: false)
    |> Stream.with_index(1)
    |> Stream.each(fn {_cells, row} -> :counters.put(last_row, 1, row) end)
  end

  defp check_line_length!(line) do
    if byte_size(line) > @max_line_bytes, do: throw(:line_too_long)
  end

  defp unreadable_file(last_row, reason) do
    row = :counters.get(last_row, 1) + 1
    # Only the position goes to the log. The file itself stays in the import
    # directory, and its content may be client data.
    Logger.info("GL CSV rejected at row #{row}: #{inspect(reason)}")

    {:error, summary(add_error(new_state(nil, nil, nil), error(row, nil, @unreadable_code)))}
  end

  defp parse_records(records, acc, fun) do
    case read_header(records) do
      {:ok, indexes} ->
        records
        |> Stream.drop(1)
        |> Stream.reject(&blank_record?/1)
        # One row past the limit is enough to report too_many_rows, and it
        # keeps chunk_by from buffering an endless entry.
        |> Stream.take(@max_rows + 1)
        |> Stream.map(fn {cells, row} -> {row, cells} end)
        |> Stream.chunk_by(&entry_key(&1, indexes))
        |> Enum.reduce_while(new_state(indexes, acc, fun), &reduce_entry/2)
        |> check_import_totals()
        |> finish()

      {:error, errors} ->
        {:error, summary(Enum.reduce(errors, new_state(nil, nil, nil), &add_error(&2, &1)))}
    end
  end

  # Header ----------------------------------------------------------------

  defp read_header(records) do
    case Enum.take(records, 1) do
      [] -> {:error, Enum.map(@column_names, &error(1, &1, "missing_column"))}
      [{names, 1}] -> header_indexes(names)
    end
  end

  defp header_indexes(names) do
    missing = @column_names -- names
    # `--` removes one occurrence per contract name, so a duplicated name
    # stays here too. The name itself is not echoed back (it is file content).
    unknown = names -- @column_names

    if missing == [] and unknown == [] do
      {:ok, Enum.map(@column_names, fn name -> Enum.find_index(names, &(&1 == name)) end)}
    else
      {:error,
       Enum.map(missing, &error(1, &1, "missing_column")) ++
         Enum.map(unknown, fn _name -> error(1, nil, @unreadable_code) end)}
    end
  end

  defp blank_record?({cells, _row}), do: Enum.all?(cells, &(&1 == ""))

  defp entry_key({_row, cells}, indexes) do
    # Positions follow Row.columns/0, where entry_number is the first.
    Enum.at(cells, hd(indexes))
  end

  # Entries ---------------------------------------------------------------

  defp new_state(indexes, acc, fun) do
    %{
      indexes: indexes,
      acc: acc,
      fun: fun,
      seen: MapSet.new(),
      rows: 0,
      entry_count: 0,
      line_count: 0,
      total_debit: Decimal.new(0),
      total_credit: Decimal.new(0),
      errors: [],
      error_count: 0,
      warnings: [],
      warning_count: 0
    }
  end

  defp reduce_entry(group, state) do
    rows = state.rows + length(group)

    if rows > @max_rows do
      {row, _cells} = Enum.at(group, @max_rows - state.rows)
      {:halt, add_error(state, error(row, nil, "too_many_rows"))}
    else
      {:cont, check_entry(group, %{state | rows: rows})}
    end
  end

  defp check_entry([{first_row, _} | _] = group, state) do
    {state, order_errors} =
      check_contiguous(entry_key(hd(group), state.indexes), first_row, state)

    parsed = Enum.map(group, fn {row, cells} -> parse_row(row, cells, state.indexes) end)

    case validate_entry(parsed) do
      {:ok, entry, warnings} ->
        state = Enum.reduce(warnings, state, &add_warning(&2, &1))
        if order_errors == [], do: accept(state, entry), else: add_errors(state, order_errors)

      {:error, errors} ->
        add_errors(state, order_errors ++ errors)
    end
  end

  # Lines of one entry must be next to each other. chunk_by has already cut
  # the file into runs of equal entry_number, so a run whose number was seen
  # before means the entry is split.
  defp check_contiguous(key, _row, state) when key in [nil, ""], do: {state, []}

  defp check_contiguous(key, row, state) do
    if MapSet.member?(state.seen, key) do
      {state, [error(row, :entry_number, "non_contiguous_entry")]}
    else
      # The set lives for the whole file. Without the copy each key would keep
      # its whole CSV line alive.
      {%{state | seen: MapSet.put(state.seen, :binary.copy(key))}, []}
    end
  end

  defp accept(%{error_count: 0} = state, entry) do
    %{
      state
      | acc: state.fun.(entry, state.acc),
        entry_count: state.entry_count + 1,
        line_count: state.line_count + entry.line_count,
        total_debit: Decimal.add(state.total_debit, entry.total_debit),
        total_credit: Decimal.add(state.total_credit, entry.total_credit)
    }
  end

  # The load is already lost, so nothing more is handed to the caller.
  defp accept(state, _entry), do: state

  defp validate_entry(parsed) do
    case Enum.flat_map(parsed, fn
           {:ok, _line} -> []
           {:error, errors} -> errors
         end) do
      [] -> parsed |> Enum.map(fn {:ok, line} -> line end) |> check_lines()
      errors -> {:error, errors}
    end
  end

  defp check_lines([first | rest] = lines) do
    total_debit = sum(lines, :debit)
    total_credit = sum(lines, :credit)

    errors =
      header_errors(first, rest) ++
        duplicate_line_errors(lines) ++
        balance_errors(first.row, total_debit, total_credit)

    if errors == [] do
      {:ok, build_entry(first, lines, total_debit, total_credit), period_warnings(first)}
    else
      {:error, errors}
    end
  end

  defp header_errors(first, rest) do
    for line <- rest,
        column <- @header_columns,
        Map.fetch!(line, column) != Map.fetch!(first, column),
        do: error(line.row, column, "inconsistent_header")
  end

  defp duplicate_line_errors(lines) do
    {errors, _seen} =
      Enum.reduce(lines, {[], MapSet.new()}, fn line, {errors, seen} ->
        if MapSet.member?(seen, line.line_number) do
          {[error(line.row, :line_number, "invalid_number") | errors], seen}
        else
          {errors, MapSet.put(seen, line.line_number)}
        end
      end)

    Enum.reverse(errors)
  end

  defp balance_errors(row, total_debit, total_credit) do
    cond do
      not Decimal.equal?(total_debit, total_credit) -> [error(row, nil, "unbalanced_entry")]
      Decimal.gt?(total_debit, Row.max_amount()) -> [error(row, :debit, "invalid_number")]
      true -> []
    end
  end

  # V2: warn only. Period 13 is the year-end adjustment period.
  defp period_warnings(%{fiscal_period: 13}), do: []

  defp period_warnings(line) do
    if line.posting_date.year == line.fiscal_year and
         line.posting_date.month == line.fiscal_period do
      []
    else
      [error(line.row, :fiscal_period, "period_mismatch")]
    end
  end

  defp build_entry(first, lines, total_debit, total_credit) do
    first
    |> Map.take([:entry_number | @header_columns])
    |> Map.merge(%{
      line_count: length(lines),
      total_debit: total_debit,
      total_credit: total_credit,
      lines: Enum.map(lines, &Map.take(&1, @line_columns))
    })
  end

  defp parse_row(row, cells, indexes) do
    case Row.parse(cells, indexes) do
      {:ok, fields} ->
        {:ok, Map.put(fields, :row, row)}

      {:error, errors} ->
        {:error, Enum.map(errors, fn {column, code} -> error(row, column, code) end)}
    end
  end

  defp sum(lines, column) do
    Enum.reduce(lines, Decimal.new(0), &Decimal.add(&2, Map.fetch!(&1, column)))
  end

  # Results ---------------------------------------------------------------

  defp check_import_totals(state) do
    # ledger_imports totals are numeric(18,2) too.
    if Decimal.gt?(state.total_debit, Row.max_amount()) or
         Decimal.gt?(state.total_credit, Row.max_amount()) do
      add_error(state, error(nil, :debit, "invalid_number"))
    else
      state
    end
  end

  defp finish(%{error_count: 0} = state), do: {:ok, state.acc, summary(state)}
  defp finish(state), do: {:error, summary(state)}

  defp summary(state) do
    %{
      entry_count: state.entry_count,
      line_count: state.line_count,
      total_debit: state.total_debit,
      total_credit: state.total_credit,
      errors: Enum.reverse(state.errors),
      error_count: state.error_count,
      warnings: Enum.reverse(state.warnings),
      warning_count: state.warning_count
    }
  end

  defp add_errors(state, errors), do: Enum.reduce(errors, state, &add_error(&2, &1))

  defp add_error(state, error) do
    errors = if state.error_count < @max_kept, do: [error | state.errors], else: state.errors
    %{state | errors: errors, error_count: state.error_count + 1}
  end

  defp add_warning(state, warning) do
    warnings =
      if state.warning_count < @max_kept, do: [warning | state.warnings], else: state.warnings

    %{state | warnings: warnings, warning_count: state.warning_count + 1}
  end

  defp error(row, column, code) do
    %{"line" => row, "field" => column && to_string(column), "code" => code}
  end
end
