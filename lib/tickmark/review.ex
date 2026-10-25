defmodule Tickmark.Review do
  @moduledoc """
  Human conclusions and review decisions, with separation of duties.

  Conclusions and decisions are immutable. Every state change and its audit
  event commit together, and subscribers are notified only after that commit.
  """

  import Ecto.Query

  alias Ecto.{Changeset, Multi}
  alias Tickmark.Accounts.Scope
  alias Tickmark.{AuditTrail, Engagements, Repo}
  alias Tickmark.Engagements.Policy
  alias Tickmark.Review.{Conclusion, ReviewDecision}
  alias Tickmark.Testing.Finding
  alias Tickmark.Triage.AiTriage

  @doc """
  Submits a new conclusion and requests review. Only preparers may submit;
  approved findings are final. The author comes from the scope, not the form.
  """
  @spec submit_conclusion(Scope.t(), Finding.t(), map()) ::
          {:ok, Conclusion.t()} | {:error, :forbidden | :invalid_state | Changeset.t()}
  def submit_conclusion(scope, %Finding{id: id}, attrs) do
    with {:ok, finding} <- fetch_finding(id),
         {:ok, _role} <- Engagements.authorize(scope, finding.engagement_id, :submit_conclusion) do
      Multi.new()
      |> Multi.run(:locked_finding, fn repo, _ ->
        lock_finding(repo, finding.id, [:open, :concluded, :rejected])
      end)
      |> Multi.insert(:conclusion, fn %{locked_finding: locked} ->
        %Conclusion{finding_id: locked.id, preparer_id: scope.user.id}
        |> Conclusion.changeset(attrs)
        |> validate_ai_triage(locked.id)
      end)
      |> Multi.update(:finding, fn %{locked_finding: locked} ->
        Finding.status_changeset(locked, :concluded)
      end)
      |> AuditTrail.append(:audit, fn %{finding: updated, conclusion: conclusion} ->
        event_attrs(scope, updated, "conclusion.submitted", %{
          "conclusion_id" => conclusion.id,
          "outcome" => to_string(conclusion.outcome),
          "ai_triage_id" => conclusion.ai_triage_id
        })
      end)
      |> Repo.transact()
      |> case do
        {:ok, %{conclusion: conclusion, finding: updated, audit: audit}} ->
          broadcast(updated, audit)
          {:ok, conclusion}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Approves or rejects the conclusion the reviewer saw. A newer submission
  makes that conclusion stale, and nobody may review their own conclusion.

  A member's denied role or self-review attempt is audited separately, after
  any review transaction has rolled back. Nonmembers cannot write events.
  """
  @spec decide(Scope.t(), Finding.t(), Ecto.UUID.t(), map()) ::
          {:ok, ReviewDecision.t()}
          | {:error, :forbidden | :self_review | :invalid_state | :stale | Changeset.t()}
  def decide(scope, %Finding{id: id}, conclusion_id, attrs) do
    with {:ok, finding} <- fetch_finding(id),
         {:ok, role} <- Engagements.fetch_role(scope, finding.engagement_id) do
      if Policy.allowed?(role, :review_conclusion) do
        review_conclusion(scope, finding, conclusion_id, attrs)
      else
        deny_review(scope, finding, attrs, "role", :forbidden)
      end
    end
  end

  defp review_conclusion(scope, finding, conclusion_id, attrs) do
    Multi.new()
    |> Multi.run(:locked_finding, fn repo, _ ->
      lock_finding(repo, finding.id, [:concluded])
    end)
    |> Multi.run(:conclusion, fn repo, %{locked_finding: locked} ->
      reviewable_conclusion(repo, locked, conclusion_id, scope.user.id)
    end)
    |> Multi.insert(:review_decision, fn %{conclusion: conclusion} ->
      %ReviewDecision{
        finding_id: conclusion.finding_id,
        conclusion_id: conclusion.id,
        preparer_id: conclusion.preparer_id,
        reviewer_id: scope.user.id
      }
      |> ReviewDecision.changeset(attrs)
    end)
    |> Multi.update(:finding, fn %{locked_finding: locked, review_decision: decision} ->
      Finding.status_changeset(locked, decision.decision)
    end)
    |> AuditTrail.append(:audit, fn %{finding: updated, review_decision: decision} ->
      payload = %{
        "conclusion_id" => decision.conclusion_id,
        "review_decision_id" => decision.id
      }

      payload =
        if decision.decision == :rejected,
          do: Map.put(payload, "comment", decision.comment),
          else: payload

      event_attrs(scope, updated, "review.#{decision.decision}", payload)
    end)
    |> Repo.transact()
    |> case do
      {:ok, %{review_decision: decision, finding: updated, audit: audit}} ->
        broadcast(updated, audit)
        {:ok, decision}

      {:error, :conclusion, :self_review, _changes} ->
        deny_review(scope, finding, attrs, "self_review", :self_review)

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # Read identity and ownership from the DB, never from a possibly stale or
  # modified struct supplied by a screen.
  defp fetch_finding(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Finding{} = finding <- Repo.get(Finding, id) do
      {:ok, Repo.preload(finding, [:test_run, :journal_entry])}
    else
      _ -> {:error, :forbidden}
    end
  end

  # Lock before inserting child rows: their FK checks take a parent key-share
  # lock, which could otherwise deadlock with another review's FOR UPDATE.
  defp lock_finding(repo, id, allowed_statuses) do
    case repo.one(from f in Finding, where: f.id == ^id, lock: "FOR UPDATE") do
      nil ->
        {:error, :forbidden}

      %Finding{} = finding ->
        if finding.status in allowed_statuses,
          do: {:ok, repo.preload(finding, :journal_entry)},
          else: {:error, :invalid_state}
    end
  end

  defp validate_ai_triage(%Changeset{valid?: false} = changeset, _finding_id), do: changeset

  defp validate_ai_triage(changeset, finding_id) do
    case Changeset.get_field(changeset, :ai_triage_id) do
      nil ->
        changeset

      id ->
        with {:ok, id} <- Ecto.UUID.cast(id),
             true <-
               Repo.exists?(
                 from t in AiTriage,
                   where: t.id == ^id and t.finding_id == ^finding_id
               ) do
          changeset
        else
          _ ->
            Changeset.add_error(changeset, :ai_triage_id, "이 검토 항목의 AI 제안을 선택해 주세요")
        end
    end
  end

  defp reviewable_conclusion(repo, finding, expected_id, reviewer_id) do
    latest =
      repo.one(
        from c in Conclusion,
          where: c.finding_id == ^finding.id,
          order_by: [desc: c.inserted_at, desc: c.id],
          limit: 1
      )

    with %Conclusion{} = conclusion <- latest,
         {:ok, id} <- Ecto.UUID.cast(expected_id),
         true <- conclusion.id == id do
      if conclusion.preparer_id == reviewer_id,
        do: {:error, :self_review},
        else: {:ok, conclusion}
    else
      _ -> {:error, :stale}
    end
  end

  defp deny_review(scope, finding, attrs, reason, error) do
    attempted =
      case attrs["decision"] do
        decision when decision in ["approved", "rejected"] -> decision
        _ -> nil
      end

    with {:ok, audit} <-
           AuditTrail.record(
             event_attrs(scope, finding, "review.denied", %{
               "reason" => reason,
               "attempted" => attempted
             })
           ) do
      AuditTrail.broadcast_appended(audit)
      {:error, error}
    end
  end

  defp event_attrs(scope, finding, action, payload) do
    %{
      engagement_id: finding.engagement_id,
      actor: AuditTrail.actor(scope),
      action: action,
      subject_type: "finding",
      subject_id: finding.id,
      payload: Map.put(payload, "entry_number", finding.journal_entry.entry_number)
    }
  end

  defp broadcast(finding, audit) do
    Engagements.broadcast(
      finding.engagement_id,
      {:finding_updated,
       %{finding_id: finding.id, status: finding.status, triage_status: finding.triage_status}}
    )

    AuditTrail.broadcast_appended(audit)
  end
end
