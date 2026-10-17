defmodule Tickmark.SchemaFixtures do
  @moduledoc """
  Inserts rows straight through the schemas, bypassing the contexts.

  For tests that need data before the owning context exists. Once a context
  has its own fixtures (for example `Tickmark.EngagementsFixtures`), prefer those.
  Values are synthetic only.
  """
  alias Tickmark.Engagements.{Engagement, Member}
  alias Tickmark.Ledger.{JournalEntry, LedgerImport}
  alias Tickmark.Repo
  alias Tickmark.Review.Conclusion
  alias Tickmark.Testing.{Finding, TestRun}
  alias Tickmark.Triage.AiTriage

  def insert_engagement(user, attrs \\ %{}) do
    %Engagement{created_by_id: user.id}
    |> Engagement.changeset(
      Enum.into(attrs, %{
        client_name: "합성상사",
        fiscal_year: 2025,
        period_end_date: ~D[2025-12-31],
        performance_materiality: "100000000"
      })
    )
    |> Repo.insert!()
  end

  def insert_member(engagement, user, role) do
    %Member{engagement_id: engagement.id, user_id: user.id}
    |> Member.changeset(%{role: role})
    |> Repo.insert!()
  end

  def insert_ledger_import(engagement, user, attrs \\ %{}) do
    %LedgerImport{engagement_id: engagement.id, uploaded_by_id: user.id}
    |> LedgerImport.create_changeset(
      Enum.into(attrs, %{
        source_kind: :generated,
        original_filename: "sample.csv",
        stored_filename: "#{Ecto.UUID.generate()}.csv",
        byte_size: 1,
        sha256: String.duplicate("0", 64)
      })
    )
    |> Repo.insert!()
  end

  def insert_journal_entry(ledger_import, attrs \\ %{}) do
    defaults = %{
      engagement_id: ledger_import.engagement_id,
      ledger_import_id: ledger_import.id,
      entry_number: "JE-#{System.unique_integer([:positive])}",
      posting_date: ~D[2025-03-31],
      document_date: ~D[2025-03-31],
      entered_at: ~N[2025-03-31 10:00:00],
      fiscal_year: 2025,
      fiscal_period: 3,
      entered_by: "user01",
      source: :manual,
      line_count: 2,
      total_debit: Decimal.new("1000000"),
      total_credit: Decimal.new("1000000")
    }

    JournalEntry
    |> struct!(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end

  def insert_test_run(ledger_import, user, attrs \\ %{}) do
    %TestRun{
      engagement_id: ledger_import.engagement_id,
      ledger_import_id: ledger_import.id,
      started_by_id: user.id
    }
    |> TestRun.create_changeset(
      Enum.into(attrs, %{rule_count: 1, triage_threshold: 25, started_at: DateTime.utc_now()})
    )
    |> Repo.insert!()
  end

  def insert_finding(test_run, journal_entry, attrs \\ %{}) do
    defaults = %{
      engagement_id: test_run.engagement_id,
      test_run_id: test_run.id,
      journal_entry_id: journal_entry.id,
      hit_count: 1,
      score: 30,
      rule_ids: ["round_amount"]
    }

    Finding
    |> struct!(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end

  def valid_ai_triage_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      model: "claude-opus-5-5",
      response_model: "claude-opus-5-5",
      prompt_version: "triage-v1",
      input_hash: String.duplicate("a", 64),
      input: %{"entry_number" => "JE-1"},
      risk_level: :medium,
      rationale: "금액이 정확히 백만 원 단위다.",
      suggested_procedures: [
        %{"procedure" => "증빙 대사", "evidence_to_obtain" => "세금계산서"}
      ],
      missing_information: [],
      stop_reason: "end_turn",
      input_tokens: 100,
      output_tokens: 50,
      latency_ms: 1200
    })
  end

  def insert_ai_triage(finding, attrs \\ %{}) do
    %AiTriage{finding_id: finding.id}
    |> AiTriage.changeset(valid_ai_triage_attrs(attrs))
    |> Repo.insert!()
  end

  def insert_conclusion(finding, preparer, attrs \\ %{}) do
    %Conclusion{finding_id: finding.id, preparer_id: preparer.id}
    |> Conclusion.changeset(Enum.into(attrs, %{outcome: :no_exception, comment: "증빙 확인 완료"}))
    |> Repo.insert!()
  end
end
