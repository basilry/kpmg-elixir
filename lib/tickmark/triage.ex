defmodule Tickmark.Triage do
  @moduledoc """
  AI triage of findings (design doc 5.5.1): queueing the work, running it
  from `Tickmark.Triage.TriageWorker`, and reading the suggestions back.

  The AI only proposes. Nothing here changes a finding's review `status`;
  only `triage_status` and the `ai_triages` rows move. Every state change
  appends its audit event in the same transaction, and every broadcast goes
  out after that transaction committed (design doc 6).

  The finding row is locked with `FOR UPDATE` before any child row (an
  `ai_triages` row or an Oban job) is written, for the reason in design doc
  5.4: the child's FK check takes FOR KEY SHARE on the finding, and two
  transactions that both hold that and then ask for FOR UPDATE deadlock.
  """
  import Ecto.Query

  alias Ecto.Multi
  alias Tickmark.{AI, AuditTrail, Engagements, Repo}
  alias Tickmark.Accounts.Scope
  alias Tickmark.AI.Prompts
  alias Tickmark.Engagements.Member
  alias Tickmark.Testing.{Finding, Rule, RuleResult, TestRun}
  alias Tickmark.Triage.{AiTriage, TriageWorker}

  require Logger

  @worker_actor {:system, "triage.triage_worker"}
  @triage_key [:finding_id, :prompt_version, :model, :input_hash]

  # Requesting ----------------------------------------------------------------

  @doc """
  Queues the AI triage of one finding at or above its run's threshold. A
  finding whose last triage finished (succeeded or failed) can be queued
  again; a new input gives a new suggestion, the same input reuses the old one.
  An unknown or malformed id looks the same as one the scope may not touch.
  """
  @spec request_finding_triage(Scope.t(), Ecto.UUID.t()) ::
          {:ok, Finding.t()} | {:error, :forbidden | :below_threshold | :already_queued}
  def request_finding_triage(%Scope{} = scope, finding_id) do
    with {:ok, id} <- cast_id(finding_id),
         %Finding{} = finding <- fetch_finding_with_run(id),
         {:ok, _role} <- Engagements.authorize(scope, finding.engagement_id, :request_triage) do
      enqueue_finding(scope, finding)
    else
      _ -> {:error, :forbidden}
    end
  end

  defp fetch_finding_with_run(id) do
    Repo.one(
      from f in Finding,
        join: r in assoc(f, :test_run),
        where: f.id == ^id,
        preload: [test_run: r]
    )
  end

  defp enqueue_finding(scope, %Finding{test_run: run} = finding) do
    Multi.new()
    |> Multi.run(:locked, fn repo, _changes ->
      lock_for_request(repo, finding.id, run.triage_threshold)
    end)
    |> Multi.update(:finding, fn %{locked: locked} ->
      Finding.triage_status_changeset(locked, :queued)
    end)
    |> Oban.insert(:job, fn %{finding: queued} -> triage_job(queued.id) end)
    |> AuditTrail.append(:audit_event, fn %{finding: queued} ->
      finding_event(queued, AuditTrail.actor(scope), "ai_triage.requested", %{})
    end)
    |> Repo.transact()
    |> case do
      {:ok, %{finding: queued, audit_event: event}} ->
        broadcast_finding(queued)
        AuditTrail.broadcast_appended(event)
        {:ok, queued}

      {:error, :locked, reason, _changes} ->
        {:error, reason}
    end
  end

  defp lock_for_request(repo, id, threshold) do
    case lock_finding(repo, id) do
      %Finding{score: score} when score < threshold -> {:error, :below_threshold}
      %Finding{triage_status: :queued} -> {:error, :already_queued}
      %Finding{} = finding -> {:ok, finding}
    end
  end

  @doc """
  Queues every finding of the run that is at or above the threshold and has
  never been triaged, best candidates first, up to `max_findings_per_request`
  from `Tickmark.AI.config/0` (`limit:` overrides it, for tests). A run that
  is still running has no findings yet, so it simply enqueues 0.

  `enqueued` is the number this request actually claimed. A finding another
  request claimed at the same moment is left out, never queued twice.
  """
  @spec request_triage(Scope.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, %{enqueued: non_neg_integer()}} | {:error, :forbidden}
  def request_triage(%Scope{} = scope, test_run_id, opts \\ []) do
    with {:ok, id} <- cast_id(test_run_id),
         %TestRun{} = run <- Repo.get(TestRun, id),
         {:ok, _role} <- Engagements.authorize(scope, run.engagement_id, :request_triage) do
      limit = Keyword.get_lazy(opts, :limit, &max_findings_per_request/0)
      enqueue_batch(scope, run, limit)
    else
      _ -> {:error, :forbidden}
    end
  end

  defp max_findings_per_request, do: Keyword.fetch!(AI.config(), :max_findings_per_request)

  defp enqueue_batch(scope, run, limit) do
    {:ok, changes} =
      Multi.new()
      |> Multi.run(:finding_ids, fn repo, _changes ->
        {:ok, claim_candidates(repo, run, limit)}
      end)
      |> Multi.merge(fn
        %{finding_ids: []} ->
          Multi.new()

        %{finding_ids: ids} ->
          Multi.new()
          |> Oban.insert_all(:jobs, Enum.map(ids, &triage_job/1))
          |> AuditTrail.append(:audit_event, fn _changes ->
            run_event(run, AuditTrail.actor(scope), "ai_triage.requested", %{
              "enqueued" => length(ids)
            })
          end)
      end)
      |> Repo.transact()

    enqueued = length(changes.finding_ids)

    Engagements.broadcast(
      run.engagement_id,
      {:triage_requested, %{test_run_id: run.id, enqueued: enqueued}}
    )

    case changes do
      %{audit_event: event} -> AuditTrail.broadcast_appended(event)
      _no_event -> :ok
    end

    {:ok, %{enqueued: enqueued}}
  end

  # Two statements on purpose (design doc 5.5.1). The SELECT ranks the
  # candidates; the UPDATE checks `triage_status == :none` again and returns
  # only the ids it changed. Under READ COMMITTED an UPDATE that had to wait
  # for a row lock re-evaluates its WHERE on the committed row, so a finding
  # a concurrent request claimed first drops out here instead of getting a
  # second job. The ranking order is kept so the best findings run first.
  defp claim_candidates(repo, run, limit) do
    case repo.all(candidate_query(run, limit)) do
      [] ->
        []

      candidates ->
        {_count, claimed} =
          repo.update_all(
            from(f in Finding,
              where: f.id in ^candidates and f.triage_status == :none,
              select: f.id
            ),
            set: [triage_status: :queued, updated_at: DateTime.utc_now()]
          )

        claimed = MapSet.new(claimed)
        Enum.filter(candidates, &MapSet.member?(claimed, &1))
    end
  end

  defp candidate_query(run, limit) do
    from f in Finding,
      join: e in assoc(f, :journal_entry),
      where: f.test_run_id == ^run.id,
      where: f.score >= ^run.triage_threshold and f.triage_status == :none,
      order_by: [desc: f.score, desc: e.total_debit, asc: e.entry_number],
      limit: ^limit,
      select: f.id
  end

  defp triage_job(finding_id), do: TriageWorker.new(%{"finding_id" => finding_id})

  # Running one triage --------------------------------------------------------

  @doc """
  For `TriageWorker` only. Calls the AI client outside any transaction and
  stores the suggestion. Returns `{:ok, :noop}` when the finding is not
  queued (already finished, or re-run after a crash). A client error is
  returned as is, with nothing written: the worker decides on retries.

  `client:` replaces the configured client, for tests that need a failure.
  """
  @spec triage_finding(Ecto.UUID.t(), keyword()) ::
          {:ok, AiTriage.t() | :noop} | {:error, Tickmark.AI.Client.error()}
  def triage_finding(finding_id, opts \\ []) do
    with {:ok, id} <- cast_id(finding_id),
         %Finding{triage_status: :queued} = finding <- load_finding(id) do
      client = Keyword.get(opts, :client, AI.client())
      input = build_input(finding, load_rule_results(finding))

      key = %{
        finding_id: finding.id,
        prompt_version: Prompts.Triage.version(),
        model: client.model(),
        input_hash: AI.input_hash(input)
      }

      # Same finding, prompt, model and input: the old suggestion stands and
      # the API is not called again (design doc 5.5.1 step 3).
      case Repo.get_by(AiTriage, key) do
        %AiTriage{} = existing -> complete(finding, {:existing, existing})
        nil -> call_and_complete(finding, client, input, key)
      end
    else
      _ -> {:ok, :noop}
    end
  end

  defp load_finding(id) do
    Repo.one(
      from f in Finding,
        where: f.id == ^id,
        preload: [journal_entry: :lines, test_run: :engagement]
    )
  end

  defp load_rule_results(%Finding{} = finding) do
    Repo.all(
      from r in RuleResult,
        where: r.test_run_id == ^finding.test_run_id,
        where: r.journal_entry_id == ^finding.journal_entry_id,
        order_by: r.rule_id
    )
  end

  defp call_and_complete(finding, client, input, key) do
    started = System.monotonic_time(:millisecond)

    with {:ok, result} <- client.triage(input, []) do
      latency_ms = System.monotonic_time(:millisecond) - started
      attrs = key |> Map.delete(:finding_id) |> Map.merge(result_attrs(result, input, latency_ms))
      changeset = AiTriage.changeset(%AiTriage{finding_id: finding.id}, attrs)

      if changeset.valid?,
        do: complete(finding, {:new, changeset}),
        else: {:error, {:fatal, :invalid_output}}
    end
  end

  # jsonb keeps string keys, so the procedures are stored that way and read
  # back identical.
  defp result_attrs(result, input, latency_ms) do
    %{
      input: input,
      response_model: result.response_model,
      risk_level: result.risk_level,
      rationale: result.rationale,
      suggested_procedures:
        Enum.map(result.suggested_procedures, fn item ->
          %{"procedure" => item.procedure, "evidence_to_obtain" => item.evidence_to_obtain}
        end),
      missing_information: result.missing_information,
      stop_reason: result.stop_reason,
      input_tokens: result.input_tokens,
      output_tokens: result.output_tokens,
      latency_ms: latency_ms
    }
  end

  defp complete(%Finding{} = finding, result) do
    Multi.new()
    |> Multi.run(:locked, fn repo, _changes -> lock_queued(repo, finding.id) end)
    |> Multi.run(:ai_triage, fn repo, _changes -> store_result(repo, result) end)
    |> Multi.update(:finding, fn %{locked: locked} ->
      Finding.triage_status_changeset(locked, :succeeded)
    end)
    |> AuditTrail.append(:audit_event, fn %{finding: done, ai_triage: {triage, reused?}} ->
      finding_event(done, {:agent, "triage:" <> triage.response_model}, "ai_triage.completed", %{
        "ai_triage_id" => triage.id,
        "risk_level" => Atom.to_string(triage.risk_level),
        "reused" => reused?
      })
    end)
    |> Repo.transact()
    |> case do
      {:ok, %{finding: done, ai_triage: {triage, _reused?}, audit_event: event}} ->
        broadcast_finding(done)
        AuditTrail.broadcast_appended(event)
        {:ok, triage}

      {:error, :locked, :noop, _changes} ->
        {:ok, :noop}
    end
  end

  defp store_result(_repo, {:existing, triage}), do: {:ok, {triage, true}}

  # on_conflict: :nothing covers a second worker that stored the same result
  # between the lookup in triage_finding/2 and this lock. The row is read
  # back by its key either way, so the event points at the row that exists.
  defp store_result(repo, {:new, changeset}) do
    {:ok, inserted} = repo.insert(changeset, on_conflict: :nothing, conflict_target: @triage_key)
    stored = repo.get_by!(AiTriage, Map.take(inserted, @triage_key))
    {:ok, {stored, stored.id != inserted.id}}
  end

  # Failing one triage --------------------------------------------------------

  @doc """
  For `TriageWorker` and `Tickmark.Jobs.FailureHandler` only. Idempotent: a
  finding that is not queued is left alone, so both can call it. The payload
  keeps only the classified reason, never the raw error.
  """
  @spec mark_failed(Ecto.UUID.t(), reason :: term()) :: :ok
  def mark_failed(finding_id, reason) do
    with {:ok, id} <- cast_id(finding_id),
         {:ok, %{finding: failed, audit_event: event}} <- fail_queued(id, failure_reason(reason)) do
      Logger.error("Triage of finding #{id} failed: #{inspect(reason)}")
      broadcast_finding(failed)
      AuditTrail.broadcast_appended(event)
    else
      _noop -> :ok
    end
  end

  defp fail_queued(id, reason) do
    Multi.new()
    |> Multi.run(:locked, fn repo, _changes -> lock_queued(repo, id) end)
    |> Multi.update(:finding, fn %{locked: locked} ->
      Finding.triage_status_changeset(locked, :failed)
    end)
    |> AuditTrail.append(:audit_event, fn %{finding: failed} ->
      finding_event(failed, @worker_actor, "ai_triage.failed", %{"reason" => reason})
    end)
    |> Repo.transact()
  end

  # Design doc 5.5.1 reason table.
  defp failure_reason({:rate_limited, _seconds}), do: "rate_limited"
  defp failure_reason(:rate_limited), do: "rate_limited"
  defp failure_reason({:retryable, _reason}), do: "transient"
  defp failure_reason({:fatal, :invalid_output}), do: "invalid_output"
  defp failure_reason({:fatal, :refusal}), do: "refusal"
  defp failure_reason({:fatal, :missing_api_key}), do: "not_configured"
  defp failure_reason({:fatal, _reason}), do: "request_rejected"
  defp failure_reason(_other), do: "worker_crashed"

  # Reading -------------------------------------------------------------------

  @doc """
  The newest suggestion of each finding the scope may view, keyed by finding
  id. Findings without one, or in an engagement the scope is not a member of,
  are left out. One query.
  """
  @spec latest_triages(Scope.t(), [Ecto.UUID.t()]) :: %{Ecto.UUID.t() => AiTriage.t()}
  def latest_triages(%Scope{user: %{id: user_id}}, finding_ids) do
    case Enum.flat_map(finding_ids, &cast_ids/1) do
      [] ->
        %{}

      ids ->
        # DISTINCT ON keeps the first row per finding in ORDER BY order, so
        # the newest suggestion wins. Ecto puts the distinct column first.
        Repo.all(
          from t in AiTriage,
            join: f in assoc(t, :finding),
            join: m in Member,
            on: m.engagement_id == f.engagement_id and m.user_id == ^user_id,
            where: t.finding_id in ^ids,
            distinct: t.finding_id,
            order_by: [desc: t.inserted_at, desc: t.id]
        )
        |> Map.new(&{&1.finding_id, &1})
    end
  end

  def latest_triages(_scope, _finding_ids), do: %{}

  # Input ---------------------------------------------------------------------

  @doc """
  The JSON-ready input for one finding (domain doc 4.1). Pure: `finding`
  must have `journal_entry` with `lines` and `test_run` with `engagement`
  preloaded, and `rule_results` are the entry's hits in this run.

  String keys only, amounts as whole-won strings, and the free text fields
  (`description`, `counterparty`) wrapped as `untrusted_text` so the prompt
  can treat them as data. Population statistics come only from the rule
  evidence (today: the rare account pair counts), never from a query here.
  No account information about users goes in.
  """
  @spec build_input(Finding.t(), [RuleResult.t()]) :: map()
  def build_input(%Finding{} = finding, rule_results) when is_list(rule_results) do
    entry = finding.journal_entry
    engagement = finding.test_run.engagement

    %{
      "engagement" => %{
        "fiscal_year" => engagement.fiscal_year,
        "period_end_date" => Date.to_iso8601(engagement.period_end_date),
        "performance_materiality" => Rule.amount_string(engagement.performance_materiality)
      },
      "entry" => entry_input(entry),
      "rule_hits" => rule_results |> Enum.sort_by(& &1.rule_id) |> Enum.map(&hit_input/1),
      "score" => finding.score,
      "context" => %{
        "entry_amount_to_materiality" =>
          ratio_string(entry.total_debit, engagement.performance_materiality),
        "account_pair_population" =>
          rule_results |> Enum.find(&(&1.rule_id == "rare_account_pair")) |> pair_population()
      }
    }
  end

  defp entry_input(entry) do
    %{
      "entry_number" => entry.entry_number,
      "posting_date" => Date.to_iso8601(entry.posting_date),
      "document_date" => Date.to_iso8601(entry.document_date),
      "entered_at" => NaiveDateTime.to_iso8601(entry.entered_at),
      "fiscal_year" => entry.fiscal_year,
      "fiscal_period" => entry.fiscal_period,
      "entered_by" => entry.entered_by,
      "approved_by" => entry.approved_by,
      "counterparty" => untrusted(entry.counterparty),
      "source" => Atom.to_string(entry.source),
      "line_count" => entry.line_count,
      "total_debit" => Rule.amount_string(entry.total_debit),
      "total_credit" => Rule.amount_string(entry.total_credit),
      "lines" => entry.lines |> Enum.sort_by(& &1.line_number) |> Enum.map(&line_input/1)
    }
  end

  defp line_input(line) do
    %{
      "line_number" => line.line_number,
      "account_code" => line.account_code,
      "account_name" => line.account_name,
      "debit" => Rule.amount_string(line.debit),
      "credit" => Rule.amount_string(line.credit),
      "description" => untrusted(line.description)
    }
  end

  defp hit_input(%RuleResult{} = result) do
    %{
      "rule_id" => result.rule_id,
      "weight" => result.score,
      "reason" => result.reason,
      "evidence" => result.details
    }
  end

  defp pair_population(nil), do: nil

  defp pair_population(%RuleResult{details: details}) do
    %{
      "population_count" => details["population_count"],
      "rare_pairs" => details["rare_pairs"]
    }
  end

  defp ratio_string(amount, materiality) do
    amount |> Decimal.div(materiality) |> Decimal.round(4) |> Decimal.to_string(:normal)
  end

  defp untrusted(nil), do: nil
  defp untrusted(text), do: %{"untrusted_text" => text}

  # Shared ---------------------------------------------------------------------

  # FOR UPDATE on the finding row alone. The entry is preloaded in a second
  # query so the lock does not spread to journal_entries.
  defp lock_finding(repo, id) do
    repo.one(from f in Finding, where: f.id == ^id, lock: "FOR UPDATE")
    |> repo.preload(:journal_entry)
  end

  defp lock_queued(repo, id) do
    case lock_finding(repo, id) do
      %Finding{triage_status: :queued} = finding -> {:ok, finding}
      _not_queued -> {:error, :noop}
    end
  end

  defp finding_event(%Finding{} = finding, actor, action, payload) do
    %{
      actor: actor,
      engagement_id: finding.engagement_id,
      action: action,
      subject_type: "finding",
      subject_id: finding.id,
      payload: Map.put(payload, "entry_number", finding.journal_entry.entry_number)
    }
  end

  defp run_event(%TestRun{} = run, actor, action, payload) do
    %{
      actor: actor,
      engagement_id: run.engagement_id,
      action: action,
      subject_type: "test_run",
      subject_id: run.id,
      payload: payload
    }
  end

  defp broadcast_finding(%Finding{} = finding) do
    Engagements.broadcast(
      finding.engagement_id,
      {:finding_updated,
       %{finding_id: finding.id, status: finding.status, triage_status: finding.triage_status}}
    )
  end

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> :error
    end
  end

  defp cast_ids(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> [id]
      :error -> []
    end
  end
end
