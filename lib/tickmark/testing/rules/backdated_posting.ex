defmodule Tickmark.Testing.Rules.BackdatedPosting do
  @moduledoc "Domain doc 2.7. Late posting or posting before the document date."
  @behaviour Tickmark.Testing.Rule

  import Ecto.Query

  alias Tickmark.Ledger.JournalEntry
  alias Tickmark.Repo
  alias Tickmark.Testing.RuleContext

  @impl true
  def id, do: "backdated_posting"
  @impl true
  def name, do: "증빙일 괴리"
  @impl true
  def description, do: "증빙일보다 오래 뒤늦게 전기되거나 증빙일 전에 전기된 전표"
  @impl true
  def weight, do: 15

  @impl true
  def default_params do
    %{
      "apply_sources" => ["manual", "system"],
      "backdate_days" => 30,
      "forward_tolerance_days" => 0
    }
  end

  @impl true
  def run(%RuleContext{ledger_import_id: import_id, params: params}) do
    backdate = params["backdate_days"]
    forward = -params["forward_tolerance_days"]

    entries =
      Repo.all(
        from e in JournalEntry,
          where: e.ledger_import_id == ^import_id and e.source in ^params["apply_sources"],
          where:
            fragment("? - ?", e.posting_date, e.document_date) >= ^backdate or
              fragment("? - ?", e.posting_date, e.document_date) < ^forward,
          order_by: e.entry_number,
          select: map(e, [:id, :posting_date, :document_date])
      )

    {:ok,
     Enum.map(entries, fn entry ->
       gap = Date.diff(entry.posting_date, entry.document_date)

       %{
         journal_entry_id: entry.id,
         reason: if(gap < 0, do: "증빙일보다 앞서 전기된 전표", else: "증빙일보다 늦게 전기된 전표"),
         details: %{
           "posting_date" => Date.to_iso8601(entry.posting_date),
           "document_date" => Date.to_iso8601(entry.document_date),
           "gap_days" => gap,
           "backdate_days" => backdate,
           "forward_tolerance_days" => -forward
         }
       }
     end)}
  end
end
