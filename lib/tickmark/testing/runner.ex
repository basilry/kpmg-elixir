defmodule Tickmark.Testing.Runner do
  @moduledoc """
  Starting a run and the job-side steps of a run (design doc 5.3, 5.4).

  `start_test_run/3` creates the run, one `test_run_rules` row per rule, the
  audit event and one `RuleWorker` job per rule in a single transaction.
  `run_rule/2` and `fail_rule/3` are called from the job side: they finish
  one rule and, when it was the last one, finalize the run.

  Every broadcast is sent after the transaction that changed the state has
  committed (design doc 6), so a screen never sees a change that rolled back.
  """
  import Ecto.Query

  alias Ecto.Multi
  alias Tickmark.Accounts.Scope
  alias Tickmark.{AuditTrail, Engagements, Repo, Testing}
  alias Tickmark.Ledger.LedgerImport

  alias Tickmark.Testing.{
    Finding,
    RuleContext,
    RuleResult,
    Rules,
    RuleWorker,
    TestRun,
    TestRunRule
  }

  require Logger

  @worker_actor {:system, "testing.rule_worker"}
  @pending [:queued, :running]
  @terminal [:succeeded, :skipped, :failed]
  @chunk_size 1000
  @error_limit 500

  # Starting a run ------------------------------------------------------------

  @doc """
  Design doc 5.3. Raises `ArgumentError` for an empty list or an id the
  registry does not know, since that is a programming error, not user input.
  """
  def start_test_run(%Scope{} = scope, %LedgerImport{} = ledger_import, rule_ids) do
    with {:ok, _role} <-
           Engagements.authorize(scope, ledger_import.engagement_id, :start_test_run),
         {:ok, ledger_import} <- fetch_ready_import(ledger_import.id) do
      insert_run(scope, ledger_import, resolve_rules(rule_ids))
    end
  end

  # The struct the screen holds may be stale, so the status is read again.
  defp fetch_ready_import(import_id) do
    case Repo.get(LedgerImport, import_id) do
      %LedgerImport{status: :succeeded} = ledger_import -> {:ok, ledger_import}
      _ -> {:error, :import_not_ready}
    end
  end

  defp resolve_rules(:all), do: resolve_rules(Rules.ids())
  defp resolve_rules([]), do: raise(ArgumentError, "rule_ids must not be empty")

  defp resolve_rules(rule_ids) when is_list(rule_ids) do
    if Enum.uniq(rule_ids) != rule_ids, do: raise(ArgumentError, "rule_ids must be unique")
    Enum.map(rule_ids, &{&1, fetch_module!(&1)})
  end

  defp fetch_module!(rule_id) do
    case Rules.fetch(rule_id) do
      {:ok, module} -> module
      :error -> raise ArgumentError, "unknown rule id: #{inspect(rule_id)}"
    end
  end

  # The run id is generated up front so the rule rows and the jobs can
  # reference it inside the same transaction.
  defp insert_run(scope, ledger_import, rules) do
    run_id = Ecto.UUID.generate()
    now = DateTime.utc_now()
    rule_ids = Enum.map(rules, fn {rule_id, _module} -> rule_id end)

    run_changeset =
      %TestRun{
        id: run_id,
        engagement_id: ledger_import.engagement_id,
        ledger_import_id: ledger_import.id,
        started_by_id: scope.user.id
      }
      |> TestRun.create_changeset(%{rule_count: length(rules), started_at: now})

    rule_rows =
      Enum.map(rules, fn {rule_id, module} ->
        %{
          test_run_id: run_id,
          rule_id: rule_id,
          params: module.default_params(),
          status: :queued,
          inserted_at: now,
          updated_at: now
        }
      end)

    jobs = Enum.map(rule_ids, &RuleWorker.new(%{"test_run_id" => run_id, "rule_id" => &1}))

    Multi.new()
    |> Multi.insert(:test_run, run_changeset)
    |> Multi.insert_all(:rules, TestRunRule, rule_rows)
    |> AuditTrail.append(:audit_event, fn %{test_run: run} ->
      audit_event(run, AuditTrail.actor(scope), "test_run.started", %{
        "ledger_import_id" => run.ledger_import_id,
        "rule_ids" => rule_ids,
        "triage_threshold" => run.triage_threshold
      })
    end)
    |> Oban.insert_all(:jobs, jobs)
    |> Repo.transact()
    |> case do
      {:ok, %{test_run: run}} ->
        broadcast_run_updated(run)
        {:ok, run}

      {:error, :test_run, %Ecto.Changeset{} = changeset, _changes} ->
        if run_in_progress?(changeset),
          do: {:error, :run_in_progress},
          else: {:error, changeset}

      {:error, _step, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}
    end
  end

  # The partial unique index (one running run per import) surfaces as a
  # unique constraint error on the changeset.
  defp run_in_progress?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:ledger_import_id, {_message, opts}} ->
        opts[:constraint_name] == "test_runs_one_running_per_import"

      _other ->
        false
    end)
  end

  # Running one rule ----------------------------------------------------------

  @doc """
  Design doc 5.4. The rule itself runs outside any transaction, so a slow
  rule never holds the run row locked.
  """
  def run_rule(test_run_id, rule_id) do
    with {:ok, module} <- fetch_module(rule_id),
         {:ok, run_id} <- cast_id(test_run_id),
         {:ok, claimed} <- claim_rule(run_id, rule_id) do
      broadcast(claimed)

      context = %RuleContext{
        test_run_id: run_id,
        ledger_import_id: claimed.run.ledger_import_id,
        engagement: claimed.run.engagement,
        params: claimed.rule.params
      }

      case module.run(context) do
        {:ok, hits} -> succeed_rule(run_id, rule_id, hits, module.weight())
        {:skip, reason} -> skip_rule(run_id, rule_id, reason)
        {:error, reason} -> {:error, reason}
      end
    else
      :noop -> {:ok, :noop}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_module(rule_id) do
    case Rules.fetch(rule_id) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unknown_rule}
    end
  end

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> :noop
    end
  end

  # queued -> running in its own short transaction. A retry finds the row
  # already running and keeps the first started_at.
  defp claim_rule(run_id, rule_id) do
    now = DateTime.utc_now()

    Repo.transact(fn ->
      with {%TestRunRule{} = rule, %TestRun{status: :running} = run} <-
             fetch_pair(run_id, rule_id),
           true <- rule.status in @pending,
           {1, _} <-
             mark_rule(run_id, rule_id, %{status: :running, hit_count: 0, error: nil}, now) do
        rule = %{rule | status: :running, started_at: rule.started_at || now}
        counts = rule_counts(run_id)
        {:ok, progress(Repo.preload(run, :engagement), rule, counts.done)}
      else
        _ -> {:error, :noop}
      end
    end)
    |> case do
      {:ok, claimed} -> {:ok, claimed}
      {:error, :noop} -> :noop
    end
  end

  defp fetch_pair(run_id, rule_id) do
    Repo.one(
      from x in TestRunRule,
        join: r in assoc(x, :test_run),
        where: x.test_run_id == ^run_id and x.rule_id == ^rule_id,
        select: {x, r}
    )
  end

  defp succeed_rule(run_id, rule_id, hits, score) do
    now = DateTime.utc_now()
    outcome = %{status: :succeeded, hit_count: length(hits), error: nil}
    rows = result_rows(run_id, rule_id, hits, score, now)

    Repo.transact(fn -> close_rule(run_id, rule_id, outcome, now, rows) end)
    |> after_close(:done)
  end

  defp skip_rule(run_id, rule_id, reason) do
    now = DateTime.utc_now()
    outcome = %{status: :skipped, hit_count: 0, error: reason}

    Repo.transact(fn -> close_rule(run_id, rule_id, outcome, now) end)
    |> after_close(:skipped)
  end

  defp after_close({:ok, closed}, result) do
    broadcast(closed)
    {:ok, result}
  end

  defp after_close({:error, :noop}, _result), do: {:ok, :noop}

  defp result_rows(run_id, rule_id, hits, score, now) do
    Enum.map(hits, fn hit ->
      %{
        test_run_id: run_id,
        rule_id: rule_id,
        journal_entry_id: hit.journal_entry_id,
        score: score,
        reason: hit.reason,
        details: hit.details,
        inserted_at: now
      }
    end)
  end

  # rule_results rows go in 1000 at a time: insert_all has a parameter limit
  # per statement, and a rule may flag tens of thousands of entries.
  defp insert_results(rows) do
    rows
    |> Enum.chunk_every(@chunk_size)
    |> Enum.each(&Repo.insert_all(RuleResult, &1))
  end

  # Failing one rule ----------------------------------------------------------

  @doc """
  Design doc 5.4. Idempotent: a rule that is already terminal is left alone,
  so the worker and the failure handler can both call it.
  """
  def fail_rule(test_run_id, rule_id, reason) do
    Logger.error(
      "Test run #{inspect(test_run_id)} rule #{inspect(rule_id)} failed: #{inspect(reason)}"
    )

    now = DateTime.utc_now()
    error = reason |> inspect() |> String.slice(0, @error_limit)
    outcome = %{status: :failed, hit_count: 0, error: error}

    with {:ok, run_id} <- cast_id(test_run_id),
         {:ok, closed} <- Repo.transact(fn -> close_rule(run_id, rule_id, outcome, now) end) do
      broadcast(closed)
    else
      _noop -> :ok
    end
  end

  # Finishing a rule and the run ----------------------------------------------

  # The lock-mark-count-finalize order from design doc 5.4. FOR UPDATE on the
  # run row serializes the transactions that finish rules of the same run, so
  # the count below always includes the rules finished before this one, and
  # exactly one transaction sees nothing pending.
  #
  # The lock comes before the rule_results insert on purpose: the FK check on
  # rule_results.test_run_id takes FOR KEY SHARE on the run row, and two
  # transactions that both hold that and then ask for FOR UPDATE deadlock.
  defp close_rule(run_id, rule_id, outcome, now, result_rows \\ []) do
    with %TestRun{} = run <- lock_run(run_id),
         {1, _} <- mark_rule(run_id, rule_id, outcome, now) do
      insert_results(result_rows)

      if outcome.status == :failed do
        record_event(run, "test_run_rule.failed", %{"rule_id" => rule_id})
      end

      counts = rule_counts(run_id)
      finalize? = counts.pending == 0 and run.status == :running
      run = if finalize?, do: finalize(run, counts.failed, now), else: run

      {:ok, progress(run, Map.put(outcome, :rule_id, rule_id), counts.done, finalize?)}
    else
      _ -> {:error, :noop}
    end
  end

  defp lock_run(run_id) do
    Repo.one(from r in TestRun, where: r.id == ^run_id, lock: "FOR UPDATE")
  end

  # Only a pending row changes. 0 rows means the rule is already terminal.
  defp mark_rule(run_id, rule_id, %{status: :running}, now) do
    from(x in TestRunRule,
      where: x.test_run_id == ^run_id and x.rule_id == ^rule_id and x.status in ^@pending,
      update: [
        set: [
          status: :running,
          started_at: fragment("COALESCE(?, ?)", x.started_at, ^now),
          updated_at: ^now
        ]
      ]
    )
    |> Repo.update_all([])
  end

  defp mark_rule(run_id, rule_id, outcome, now) do
    from(x in TestRunRule,
      where: x.test_run_id == ^run_id and x.rule_id == ^rule_id and x.status in ^@pending
    )
    |> Repo.update_all(
      set: [
        status: outcome.status,
        hit_count: outcome.hit_count,
        error: outcome.error,
        finished_at: now,
        updated_at: now
      ]
    )
  end

  defp rule_counts(run_id) do
    Repo.one(
      from x in TestRunRule,
        where: x.test_run_id == ^run_id,
        select: %{
          pending: filter(count(x.id), x.status in ^@pending),
          done: filter(count(x.id), x.status in ^@terminal),
          failed: filter(count(x.id), x.status == :failed)
        }
    )
  end

  # One finding per flagged entry, built in the database from rule_results.
  defp finalize(%TestRun{} = run, failed_count, now) do
    {finding_count, _} = Repo.insert_all(Finding, findings_query(run, now))
    status = if failed_count == 0, do: :completed, else: :completed_with_errors

    {1, _} =
      from(r in TestRun, where: r.id == ^run.id)
      |> Repo.update_all(
        set: [status: status, finding_count: finding_count, finished_at: now, updated_at: now]
      )

    run = %{run | status: status, finding_count: finding_count, finished_at: now}

    record_event(run, "test_run.completed", %{
      "status" => Atom.to_string(status),
      "finding_count" => finding_count
    })

    run
  end

  defp findings_query(run, now) do
    from x in RuleResult,
      where: x.test_run_id == ^run.id,
      group_by: x.journal_entry_id,
      select: %{
        engagement_id: type(^run.engagement_id, :binary_id),
        test_run_id: type(^run.id, :binary_id),
        journal_entry_id: x.journal_entry_id,
        hit_count: count(x.id),
        score: fragment("LEAST(100, SUM(?))", x.score),
        rule_ids: fragment("ARRAY_AGG(? ORDER BY ?)", x.rule_id, x.rule_id),
        inserted_at: type(^now, :utc_datetime_usec),
        updated_at: type(^now, :utc_datetime_usec)
      }
  end

  defp record_event(run, action, payload) do
    {:ok, _event} = AuditTrail.record(audit_event(run, @worker_actor, action, payload))
  end

  defp audit_event(run, actor, action, payload) do
    %{
      actor: actor,
      action: action,
      engagement_id: run.engagement_id,
      subject_type: "test_run",
      subject_id: run.id,
      payload: payload
    }
  end

  # Broadcasts ----------------------------------------------------------------

  defp progress(run, rule, done, finalized? \\ false) do
    %{run: run, rule: rule, done: done, finalized?: finalized?}
  end

  # Called after the transaction committed. Order: the rule's progress, the
  # run row for the engagement screens, then completion.
  defp broadcast(%{run: run, rule: rule, done: done, finalized?: finalized?}) do
    broadcast_run(run.id, {
      :rule_progress,
      %{
        test_run_id: run.id,
        rule_id: rule.rule_id,
        status: rule.status,
        hit_count: rule.hit_count,
        done: done,
        total: run.rule_count
      }
    })

    broadcast_run_updated(run)

    if finalized? do
      broadcast_run(run.id, {:run_completed, run_summary(run)})
    end

    :ok
  end

  defp broadcast_run_updated(%TestRun{} = run) do
    Engagements.broadcast(run.engagement_id, {:test_run_updated, run_summary(run)})
  end

  defp run_summary(run) do
    %{test_run_id: run.id, status: run.status, finding_count: run.finding_count}
  end

  defp broadcast_run(run_id, message) do
    Phoenix.PubSub.broadcast(Tickmark.PubSub, Testing.run_topic(run_id), message)
  end
end
