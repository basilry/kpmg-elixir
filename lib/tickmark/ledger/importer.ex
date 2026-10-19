defmodule Tickmark.Ledger.Importer do
  @moduledoc """
  Writes the entries of a GL file while `Tickmark.Ledger.CsvParser` reads it
  (architecture doc 9.3).

  Entries are buffered and written with `Repo.insert_all/3` in chunks of 1000.
  The caller runs this inside one transaction, so rows written before a later
  error are rolled back with it.
  """
  alias Tickmark.Ledger.{CsvParser, JournalEntry, JournalLine, LedgerImport}
  alias Tickmark.Repo

  @chunk_size 1000

  @spec run(LedgerImport.t(), Path.t()) ::
          {:ok, CsvParser.summary()} | {:error, CsvParser.summary()}
  def run(%LedgerImport{} = ledger_import, path) do
    # Values shared by every row go to PostgreSQL once per statement instead
    # of once per row.
    shared = %{
      import_id: ledger_import.id,
      engagement_id: ledger_import.engagement_id,
      now: DateTime.utc_now()
    }

    case CsvParser.parse(path, {0, []}, &buffer(&1, &2, shared)) do
      {:ok, {_count, entries}, summary} ->
        insert_chunk(entries, shared)
        {:ok, summary}

      {:error, summary} ->
        {:error, summary}
    end
  end

  # The count avoids length/1, which walks the whole list each time.
  defp buffer(entry, {count, entries}, shared) when count + 1 == @chunk_size do
    insert_chunk([entry | entries], shared)
    {0, []}
  end

  defp buffer(entry, {count, entries}, _shared), do: {count + 1, [entry | entries]}

  defp insert_chunk([], _shared), do: :ok

  defp insert_chunk(entries, shared) do
    # ids are made here so lines can point at their entry without a
    # RETURNING round trip.
    entries = entries |> Enum.reverse() |> Enum.map(&Map.put(&1, :id, Ecto.UUID.generate()))

    Repo.insert_all(JournalEntry, Enum.map(entries, &entry_row/1),
      placeholders: Map.take(shared, [:import_id, :engagement_id, :now])
    )

    # 1000 lines x 8 values stay far below the 65,535 parameter limit.
    entries
    |> Enum.flat_map(&line_rows/1)
    |> Enum.chunk_every(@chunk_size)
    |> Enum.each(fn rows ->
      Repo.insert_all(JournalLine, rows, placeholders: Map.take(shared, [:import_id, :now]))
    end)
  end

  defp entry_row(entry) do
    entry
    |> Map.delete(:lines)
    |> Map.merge(%{
      engagement_id: {:placeholder, :engagement_id},
      ledger_import_id: {:placeholder, :import_id},
      inserted_at: {:placeholder, :now}
    })
  end

  defp line_rows(entry) do
    Enum.map(entry.lines, fn line ->
      Map.merge(line, %{
        journal_entry_id: entry.id,
        ledger_import_id: {:placeholder, :import_id},
        inserted_at: {:placeholder, :now}
      })
    end)
  end
end
