defmodule Tickmark.Testing do
  @moduledoc """
  Journal entry testing: rule runs over one ledger import and the findings
  they produce.

  This module holds the read side. Starting a run and the job-side steps
  (running one rule, failing one rule, finishing the run) live in
  `Tickmark.Testing.Runner` and are reachable through the delegates below,
  so callers only ever use `Tickmark.Testing`.
  """
  import Ecto.Query

  alias Tickmark.Accounts.Scope
  alias Tickmark.Engagements
  alias Tickmark.Engagements.Member
  alias Tickmark.Ledger.LedgerImport
  alias Tickmark.Repo
  alias Tickmark.Testing.{Finding, Rules, Runner, TestRun}

  @spec list_rules() :: [module()]
  def list_rules, do: Rules.all()

  @spec run_topic(Ecto.UUID.t()) :: String.t()
  def run_topic(test_run_id), do: "test_run:#{test_run_id}"

  @spec start_test_run(Scope.t(), LedgerImport.t(), [String.t()] | :all) ::
          {:ok, TestRun.t()}
          | {:error, :forbidden | :import_not_ready | :run_in_progress | Ecto.Changeset.t()}
  defdelegate start_test_run(scope, ledger_import, rule_ids), to: Runner

  @doc "For `RuleWorker` only."
  @spec run_rule(Ecto.UUID.t(), String.t()) ::
          {:ok, :done | :skipped | :noop} | {:error, term()}
  defdelegate run_rule(test_run_id, rule_id), to: Runner

  @doc "For `RuleWorker` and `Tickmark.Jobs.FailureHandler` only."
  @spec fail_rule(Ecto.UUID.t(), String.t(), term()) :: :ok
  defdelegate fail_rule(test_run_id, rule_id, reason), to: Runner

  @doc """
  Runs of an engagement, newest first, with their rules preloaded in
  registry order. Empty without :view.
  """
  @spec list_test_runs(Scope.t(), Ecto.UUID.t()) :: [TestRun.t()]
  def list_test_runs(scope, engagement_id) do
    case Engagements.authorize(scope, engagement_id, :view) do
      {:ok, _role} ->
        from(r in TestRun,
          where: r.engagement_id == ^engagement_id,
          order_by: [desc: r.started_at, desc: r.id]
        )
        |> Repo.all()
        |> Repo.preload(:test_run_rules)
        |> Enum.map(&sort_rules/1)

      {:error, :forbidden} ->
        []
    end
  end

  @doc """
  Raises `Ecto.NoResultsError` for an unknown or malformed id and for a run
  the scope cannot view, so the two cases look the same.
  """
  @spec get_test_run!(Scope.t(), Ecto.UUID.t()) :: TestRun.t()
  def get_test_run!(scope, id) do
    case fetch_visible_run(scope, id) do
      {:ok, run} -> run |> Repo.preload(:test_run_rules) |> sort_rules()
      :error -> raise Ecto.NoResultsError, queryable: TestRun
    end
  end

  @spec subscribe_test_run(Scope.t(), Ecto.UUID.t()) :: :ok | {:error, :forbidden}
  def subscribe_test_run(scope, test_run_id) do
    case fetch_visible_run(scope, test_run_id) do
      {:ok, run} -> Phoenix.PubSub.subscribe(Tickmark.PubSub, run_topic(run.id))
      :error -> {:error, :forbidden}
    end
  end

  @doc """
  Findings of one run with `journal_entry` preloaded, highest score first,
  then entry number. Empty without :view.

  Filters (atom keys, all optional):
    * `:queue` - `:review` (default, score >= the run's triage_threshold),
      `:minor` (below it) or `:all`
    * `:status` - one finding status
    * `:rule_id` - findings that rule hit
  """
  @spec list_findings(Scope.t(), Ecto.UUID.t(), map()) :: [Finding.t()]
  def list_findings(scope, test_run_id, filters \\ %{}) do
    case fetch_visible_run(scope, test_run_id) do
      {:ok, run} ->
        from(f in Finding,
          join: e in assoc(f, :journal_entry),
          where: f.test_run_id == ^run.id,
          order_by: [desc: f.score, asc: e.entry_number],
          preload: [journal_entry: e]
        )
        |> filter_queue(Map.get(filters, :queue, :review), run.triage_threshold)
        |> filter_status(Map.get(filters, :status))
        |> filter_rule(Map.get(filters, :rule_id))
        |> Repo.all()

      :error ->
        []
    end
  end

  @doc """
  Finding counts on each side of the run's triage threshold, in one query.
  `approved` counts approved findings in the review queue. Used by the S2
  run list and stats and the S4 tabs (screen design C-07). Zeros without :view.
  """
  @spec count_findings(Scope.t(), Ecto.UUID.t()) :: %{
          review_queue: non_neg_integer(),
          minor: non_neg_integer(),
          approved: non_neg_integer()
        }
  def count_findings(scope, test_run_id) do
    case fetch_visible_run(scope, test_run_id) do
      {:ok, run} ->
        threshold = run.triage_threshold

        Repo.one(
          from f in Finding,
            where: f.test_run_id == ^run.id,
            select: %{
              review_queue: filter(count(f.id), f.score >= ^threshold),
              minor: filter(count(f.id), f.score < ^threshold),
              approved: filter(count(f.id), f.score >= ^threshold and f.status == :approved)
            }
        )

      :error ->
        %{review_queue: 0, minor: 0, approved: 0}
    end
  end

  @doc """
  The newest run of every engagement the scope belongs to, for the S1 list.
  `review_queue` counts findings at or above that run's threshold and is nil
  while the run is still running. Engagements without a run are left out.
  Two queries, however many engagements there are.
  """
  @spec latest_run_summaries(Scope.t()) :: %{
          Ecto.UUID.t() => %{
            status: :running | :completed | :completed_with_errors,
            review_queue: non_neg_integer() | nil
          }
        }
  def latest_run_summaries(%Scope{user: %{id: user_id}}) do
    # DISTINCT ON keeps the first row of each engagement in ORDER BY order,
    # so the newest run wins. Ecto puts the distinct column first in ORDER BY.
    latest =
      Repo.all(
        from r in TestRun,
          join: m in Member,
          on: m.engagement_id == r.engagement_id and m.user_id == ^user_id,
          distinct: r.engagement_id,
          order_by: [desc: r.started_at, desc: r.id]
      )

    finished_ids = for run <- latest, run.status != :running, do: run.id

    review_counts =
      Repo.all(
        from f in Finding,
          join: r in assoc(f, :test_run),
          where: f.test_run_id in ^finished_ids and f.score >= r.triage_threshold,
          group_by: f.test_run_id,
          select: {f.test_run_id, count(f.id)}
      )
      |> Map.new()

    Map.new(latest, fn run ->
      review_queue = if run.status == :running, do: nil, else: Map.get(review_counts, run.id, 0)
      {run.engagement_id, %{status: run.status, review_queue: review_queue}}
    end)
  end

  @doc """
  One visible finding with its entry, ordered lines and review history.
  Missing, malformed and inaccessible ids all raise `Ecto.NoResultsError`.
  """
  @spec get_finding!(Scope.t(), Ecto.UUID.t()) :: Finding.t()
  def get_finding!(scope, id) do
    case fetch_visible_finding(scope, id) do
      {:ok, finding} ->
        Repo.preload(finding,
          journal_entry: [lines: from(l in Tickmark.Ledger.JournalLine, order_by: l.line_number)],
          test_run: [],
          ai_triages:
            from(t in Tickmark.Triage.AiTriage, order_by: [desc: t.inserted_at, desc: t.id]),
          conclusions:
            from(c in Tickmark.Review.Conclusion,
              order_by: [asc: c.inserted_at, asc: c.id],
              preload: :preparer
            ),
          review_decisions:
            from(d in Tickmark.Review.ReviewDecision,
              order_by: [asc: d.inserted_at, asc: d.id],
              preload: :reviewer
            )
        )

      :error ->
        raise Ecto.NoResultsError, queryable: Finding
    end
  end

  @doc """
  Hits for the finding's run and entry, in registry order. Empty without
  :view. The persisted finding supplies the ids and engagement membership.
  """
  @spec list_rule_results(Scope.t(), Finding.t()) :: [Tickmark.Testing.RuleResult.t()]
  def list_rule_results(scope, %Finding{id: id}) do
    case fetch_visible_finding(scope, id) do
      {:ok, finding} ->
        positions = Rules.ids() |> Enum.with_index() |> Map.new()

        from(r in Tickmark.Testing.RuleResult,
          where:
            r.test_run_id == ^finding.test_run_id and
              r.journal_entry_id == ^finding.journal_entry_id
        )
        |> Repo.all()
        |> Enum.sort_by(&{Map.get(positions, &1.rule_id, map_size(positions)), &1.rule_id})

      :error ->
        []
    end
  end

  defp fetch_visible_finding(scope, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Finding{} = finding <- Repo.get(Finding, id),
         {:ok, _role} <- Engagements.authorize(scope, finding.engagement_id, :view) do
      {:ok, finding}
    else
      _ -> :error
    end
  end

  defp fetch_visible_run(scope, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %TestRun{} = run <- Repo.get(TestRun, id),
         {:ok, _role} <- Engagements.authorize(scope, run.engagement_id, :view) do
      {:ok, run}
    else
      _ -> :error
    end
  end

  defp filter_queue(query, :review, threshold), do: where(query, [f], f.score >= ^threshold)
  defp filter_queue(query, :minor, threshold), do: where(query, [f], f.score < ^threshold)
  defp filter_queue(query, :all, _threshold), do: query

  defp filter_status(query, nil), do: query
  defp filter_status(query, status), do: where(query, [f], f.status == ^status)

  defp filter_rule(query, nil), do: query
  defp filter_rule(query, rule_id), do: where(query, [f], ^rule_id in f.rule_ids)

  # Registry order, so every screen lists rules the same way. Ids the
  # registry does not know (test-only rules) go last.
  defp sort_rules(%TestRun{test_run_rules: rules} = run) do
    order = Rules.ids()
    position = fn rule -> Enum.find_index(order, &(&1 == rule.rule_id)) || length(order) end
    %{run | test_run_rules: Enum.sort_by(rules, &{position.(&1), &1.rule_id})}
  end
end
