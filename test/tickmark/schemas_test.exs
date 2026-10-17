defmodule Tickmark.SchemasTest do
  @moduledoc """
  DB constraints and shared changesets from the data model doc, checked against
  the real schema. Context behaviour is tested in each context's own tests.
  """
  use Tickmark.DataCase, async: true

  import Tickmark.AccountsFixtures
  import Tickmark.SchemaFixtures

  alias Tickmark.Review.{Conclusion, ReviewDecision}
  alias Tickmark.Testing.{Finding, TestRun}
  alias Tickmark.Triage.AiTriage

  setup do
    preparer = user_fixture()
    engagement = insert_engagement(preparer)
    ledger_import = insert_ledger_import(engagement, preparer)
    entry = insert_journal_entry(ledger_import)
    test_run = insert_test_run(ledger_import, preparer)
    finding = insert_finding(test_run, entry)

    %{preparer: preparer, ledger_import: ledger_import, test_run: test_run, finding: finding}
  end

  describe "Finding.status_changeset/2" do
    test "follows the review state machine" do
      allowed = [
        {:open, :concluded},
        {:concluded, :concluded},
        {:concluded, :approved},
        {:concluded, :rejected},
        {:rejected, :concluded}
      ]

      for from <- [:open, :concluded, :rejected, :approved],
          to <- [:open, :concluded, :approved, :rejected] do
        changeset = Finding.status_changeset(%Finding{status: from}, to)
        assert changeset.valid? == {from, to} in allowed, "#{from} -> #{to}"
      end
    end

    test "persists the new status", %{finding: finding} do
      {:ok, finding} = finding |> Finding.status_changeset(:concluded) |> Repo.update()
      assert Repo.reload!(finding).status == :concluded
    end
  end

  describe "Finding.triage_status_changeset/2" do
    test "queues from none or a finished triage, finishes only from queued" do
      assert Finding.triage_status_changeset(%Finding{triage_status: :none}, :queued).valid?
      assert Finding.triage_status_changeset(%Finding{triage_status: :failed}, :queued).valid?
      assert Finding.triage_status_changeset(%Finding{triage_status: :queued}, :succeeded).valid?
      refute Finding.triage_status_changeset(%Finding{triage_status: :queued}, :queued).valid?
      refute Finding.triage_status_changeset(%Finding{triage_status: :none}, :succeeded).valid?
    end
  end

  test "only one running test run per import", %{preparer: preparer, ledger_import: ledger_import} do
    {:error, changeset} =
      %TestRun{
        engagement_id: ledger_import.engagement_id,
        ledger_import_id: ledger_import.id,
        started_by_id: preparer.id
      }
      |> TestRun.create_changeset(%{
        rule_count: 1,
        triage_threshold: 25,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert()

    assert errors_on(changeset).ledger_import_id == ["has already been taken"]
  end

  describe "AiTriage" do
    test "keeps suggested_procedures as a JSON array of string-keyed maps", %{finding: finding} do
      triage = insert_ai_triage(finding)

      assert Repo.reload!(triage).suggested_procedures == [
               %{"procedure" => "증빙 대사", "evidence_to_obtain" => "세금계산서"}
             ]
    end

    test "the same finding, prompt, model and input is stored once", %{finding: finding} do
      insert_ai_triage(finding)

      {:error, changeset} =
        %AiTriage{finding_id: finding.id}
        |> AiTriage.changeset(valid_ai_triage_attrs())
        |> Repo.insert()

      assert errors_on(changeset).finding_id == ["has already been taken"]
    end

    test "rows cannot be updated", %{finding: finding} do
      triage = insert_ai_triage(finding)

      assert_raise Postgrex.Error, ~r/append-only table ai_triages: UPDATE/, fn ->
        Repo.update_all(where(AiTriage, id: ^triage.id), set: [risk_level: "high"])
      end
    end
  end

  describe "ReviewDecision" do
    setup %{finding: finding, preparer: preparer} do
      %{conclusion: insert_conclusion(finding, preparer), reviewer: user_fixture()}
    end

    defp decide(conclusion, preparer_id, reviewer_id, attrs) do
      %ReviewDecision{
        finding_id: conclusion.finding_id,
        conclusion_id: conclusion.id,
        preparer_id: preparer_id,
        reviewer_id: reviewer_id
      }
      |> ReviewDecision.changeset(attrs)
      |> Repo.insert()
    end

    test "a reviewer approves another person's conclusion", ctx do
      assert {:ok, %{decision: :approved}} =
               decide(ctx.conclusion, ctx.preparer.id, ctx.reviewer.id, %{decision: :approved})
    end

    test "the DB rejects self-review even without the context check", ctx do
      {:error, changeset} =
        decide(ctx.conclusion, ctx.preparer.id, ctx.preparer.id, %{decision: :approved})

      assert errors_on(changeset).reviewer_id == ["is invalid"]
    end

    test "a forged preparer_id breaks the composite foreign key", ctx do
      someone_else = user_fixture()

      {:error, changeset} =
        decide(ctx.conclusion, someone_else.id, ctx.reviewer.id, %{decision: :approved})

      assert errors_on(changeset).conclusion_id == ["does not exist"]
    end

    test "a rejection needs a comment", ctx do
      {:error, changeset} =
        decide(ctx.conclusion, ctx.preparer.id, ctx.reviewer.id, %{decision: :rejected})

      assert errors_on(changeset).comment == ["can't be blank"]
    end

    test "one decision per conclusion", ctx do
      {:ok, _} = decide(ctx.conclusion, ctx.preparer.id, ctx.reviewer.id, %{decision: :approved})

      {:error, changeset} =
        decide(ctx.conclusion, ctx.preparer.id, ctx.reviewer.id, %{decision: :approved})

      assert errors_on(changeset).conclusion_id == ["has already been taken"]
    end

    test "conclusions cannot be deleted", %{conclusion: conclusion} do
      assert_raise Postgrex.Error, ~r/append-only table conclusions: DELETE/, fn ->
        Repo.delete_all(where(Conclusion, id: ^conclusion.id))
      end
    end
  end
end
