defmodule Tickmark.LedgerTest do
  use Tickmark.DataCase, async: true
  use Oban.Testing, repo: Tickmark.Repo

  import ExUnit.CaptureLog
  import Tickmark.AccountsFixtures
  import Tickmark.LedgerFixtures
  import Tickmark.SchemaFixtures

  alias Tickmark.Accounts.Scope
  alias Tickmark.AuditTrail.AuditEvent
  alias Tickmark.Engagements
  alias Tickmark.Ledger
  alias Tickmark.Ledger.{Generator, ImportWorker, JournalEntry, JournalLine, LedgerImport}

  setup do
    preparer = user_fixture()
    reviewer = user_fixture()
    engagement = insert_engagement(preparer)
    insert_member(engagement, preparer, :preparer)
    insert_member(engagement, reviewer, :reviewer)

    %{
      engagement: engagement,
      preparer: Scope.for_user(preparer),
      reviewer: Scope.for_user(reviewer),
      outsider: user_scope_fixture()
    }
  end

  defp audit_events(subject_id) do
    Repo.all(from e in AuditEvent, where: e.subject_id == ^subject_id, order_by: e.seq)
  end

  defp count_rows(schema, import_id) do
    Repo.aggregate(from(r in schema, where: r.ledger_import_id == ^import_id), :count)
  end

  defp sha256(content), do: :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

  defp labels_path(ledger_import) do
    String.replace_suffix(stored_path(ledger_import), ".csv", ".labels.csv")
  end

  defp remove_sample_files(ledger_import) do
    on_exit(fn ->
      File.rm(stored_path(ledger_import))
      File.rm(labels_path(ledger_import))
    end)
  end

  describe "create_import/3" do
    test "copies the file and registers a pending upload with its job and audit event", ctx do
      csv = gl_csv(gl_entry("JE-0001"))
      path = write_csv!(csv)
      :ok = Engagements.subscribe(ctx.preparer, ctx.engagement.id)

      assert {:ok, %LedgerImport{} = imported} =
               Ledger.create_import(ctx.preparer, ctx.engagement, %{
                 path: path,
                 filename: "browser/folder/gl-2025.csv"
               })

      on_exit(fn -> File.rm(stored_path(imported)) end)

      assert imported.status == :pending
      assert imported.source_kind == :upload
      assert imported.original_filename == "gl-2025.csv"
      assert imported.engagement_id == ctx.engagement.id
      assert imported.uploaded_by_id == ctx.preparer.user.id
      assert imported.stored_filename =~ ~r/\A[0-9a-f-]{36}\.csv\z/
      assert File.read!(stored_path(imported)) == csv
      assert imported.byte_size == byte_size(csv)
      assert imported.sha256 == sha256(csv)

      assert_enqueued(
        worker: ImportWorker,
        queue: :ingest,
        args: %{"ledger_import_id" => imported.id}
      )

      assert [event] = audit_events(imported.id)
      assert event.action == "ledger_import.created"
      assert event.actor_type == :user
      assert event.actor_id == ctx.preparer.user.id
      assert event.engagement_id == ctx.engagement.id
      assert event.subject_type == "ledger_import"

      assert event.payload == %{
               "source_kind" => "upload",
               "original_filename" => "gl-2025.csv",
               "byte_size" => byte_size(csv),
               "sha256" => sha256(csv)
             }

      import_id = imported.id

      assert_receive {:import_updated,
                      %{import_id: ^import_id, status: :pending, entry_count: 0, error_count: 0}}

      assert_audit_appended(event)
      refute_received {:audit_appended, _}
    end

    test "refuses reviewers, non-members and missing scopes", ctx do
      path = write_csv!(gl_csv(gl_entry("JE-0001")))
      :ok = Engagements.subscribe(ctx.preparer, ctx.engagement.id)

      for scope <- [ctx.reviewer, ctx.outsider, nil] do
        assert Ledger.create_import(scope, ctx.engagement, %{path: path, filename: "gl.csv"}) ==
                 {:error, :forbidden}
      end

      assert Repo.aggregate(LedgerImport, :count) == 0

      assert Repo.aggregate(
               from(e in AuditEvent, where: e.subject_type == "ledger_import"),
               :count
             ) == 0

      refute_enqueued(worker: ImportWorker)
      refute_received {:audit_appended, _}
    end

    test "refuses a file over 20,000,000 bytes", ctx do
      :ok = Engagements.subscribe(ctx.preparer, ctx.engagement.id)
      # A sparse file: the size is 20,000,001 bytes, but only one byte is written.
      path = write_csv!("")
      {:ok, file} = File.open(path, [:write, :binary])
      {:ok, 20_000_000} = :file.position(file, 20_000_000)
      :ok = IO.binwrite(file, "x")
      :ok = File.close(file)
      assert File.stat!(path).size == 20_000_001

      assert Ledger.create_import(ctx.preparer, ctx.engagement, %{path: path, filename: "gl.csv"}) ==
               {:error, :file_too_large}

      assert Repo.aggregate(LedgerImport, :count) == 0
      refute_enqueued(worker: ImportWorker)
      refute_received {:audit_appended, _}
    end

    test "returns the changeset for an empty file", ctx do
      path = write_csv!("")
      :ok = Engagements.subscribe(ctx.preparer, ctx.engagement.id)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Ledger.create_import(ctx.preparer, ctx.engagement, %{
                 path: path,
                 filename: "gl.csv"
               })

      assert %{byte_size: [_]} = errors_on(changeset)
      assert Repo.aggregate(LedgerImport, :count) == 0
      refute_enqueued(worker: ImportWorker)
      refute_received {:audit_appended, _}
    end
  end

  describe "generate_sample_import/3" do
    test "writes the generated GL and labels and registers a generated import", ctx do
      %{gl_csv: gl_csv, labels_csv: labels_csv} = Generator.generate(seed: 7)
      :ok = Engagements.subscribe(ctx.preparer, ctx.engagement.id)

      assert {:ok, %LedgerImport{} = imported} =
               Ledger.generate_sample_import(ctx.preparer, ctx.engagement, seed: 7)

      remove_sample_files(imported)

      assert imported.status == :pending
      assert imported.source_kind == :generated
      assert imported.original_filename == "synthetic-gl-seed-7.csv"
      assert imported.stored_filename =~ ~r/\A[0-9a-f-]{36}\.csv\z/
      assert File.read!(stored_path(imported)) == gl_csv
      assert File.read!(labels_path(imported)) == labels_csv
      assert imported.byte_size == byte_size(gl_csv)
      assert imported.sha256 == sha256(gl_csv)

      assert_enqueued(worker: ImportWorker, args: %{"ledger_import_id" => imported.id})

      assert [
               %{action: "ledger_import.created", payload: %{"source_kind" => "generated"}} =
                 event
             ] =
               audit_events(imported.id)

      assert_audit_appended(event)
      refute_received {:audit_appended, _}
    end

    test "uses the generator's default seed without options", ctx do
      assert {:ok, imported} = Ledger.generate_sample_import(ctx.preparer, ctx.engagement)
      remove_sample_files(imported)

      assert imported.original_filename ==
               "synthetic-gl-seed-#{Generator.default_seed()}.csv"
    end

    test "refuses reviewers, non-members and unknown options", ctx do
      assert Ledger.generate_sample_import(ctx.reviewer, ctx.engagement, seed: 7) ==
               {:error, :forbidden}

      assert Ledger.generate_sample_import(ctx.outsider, ctx.engagement, seed: 7) ==
               {:error, :forbidden}

      assert Ledger.list_imports(ctx.preparer, ctx.engagement.id) == []

      assert_raise ArgumentError, fn ->
        Ledger.generate_sample_import(ctx.preparer, ctx.engagement, target_lines: 100)
      end
    end

    # 10/18 completion check (planning doc): the generator's file goes through
    # CsvParser and Importer as it is, CRLF line endings included.
    test "loads the default synthetic GL, one entry per label row", ctx do
      {:ok, imported} = Ledger.generate_sample_import(ctx.preparer, ctx.engagement)
      remove_sample_files(imported)

      assert {:ok, %{status: :succeeded} = loaded} = Ledger.process_import(imported.id)
      assert loaded.entry_count == 8_341
      assert loaded.line_count == 19_804
      assert loaded.error_count == 0
      assert Decimal.equal?(loaded.total_debit, loaded.total_credit)
      assert count_rows(JournalLine, imported.id) == 19_804

      [_header | label_rows] =
        imported |> labels_path() |> File.read!() |> String.split("\r\n", trim: true)

      label_numbers = MapSet.new(label_rows, &(&1 |> String.split(",") |> hd()))

      entry_numbers =
        Repo.all(
          from e in JournalEntry,
            where: e.ledger_import_id == ^imported.id,
            select: e.entry_number
        )

      assert MapSet.new(entry_numbers) == label_numbers
    end
  end

  describe "process_import/1" do
    test "loads every entry and line with the file totals and warnings", ctx do
      csv =
        gl_csv(
          gl_entry("JE-0001", "1000000") ++
            gl_entry("JE-0002", "250000", %{posting_date: "2025-04-01"})
        )

      imported = ledger_import_fixture(ctx.preparer, ctx.engagement, csv)
      :ok = Engagements.subscribe(ctx.preparer, ctx.engagement.id)

      assert {:ok, %LedgerImport{} = loaded} = Ledger.process_import(imported.id)

      assert loaded.status == :succeeded
      assert loaded.entry_count == 2
      assert loaded.line_count == 4
      assert Decimal.equal?(loaded.total_debit, 1_250_000)
      assert Decimal.equal?(loaded.total_credit, 1_250_000)
      assert loaded.error_count == 0 and loaded.errors == []
      assert loaded.warning_count == 1

      assert loaded.warnings == [
               %{"line" => 4, "field" => "fiscal_period", "code" => "period_mismatch"}
             ]

      assert %DateTime{} = loaded.started_at
      assert DateTime.compare(loaded.finished_at, loaded.started_at) in [:gt, :eq]
      assert Ledger.get_import!(ctx.preparer, imported.id).status == :succeeded

      entries =
        Repo.all(
          from e in JournalEntry,
            where: e.ledger_import_id == ^imported.id,
            order_by: e.entry_number
        )

      assert Enum.map(entries, & &1.entry_number) == ["JE-0001", "JE-0002"]
      assert Enum.all?(entries, &(&1.engagement_id == ctx.engagement.id))
      assert Enum.all?(entries, &match?(%DateTime{}, &1.inserted_at))
      assert count_rows(JournalLine, imported.id) == 4

      assert [_created, event] = audit_events(imported.id)
      assert event.action == "ledger_import.succeeded"
      assert {event.actor_type, event.actor_id} == {:system, "ledger.import_worker"}

      assert event.payload == %{
               "entry_count" => 2,
               "line_count" => 4,
               "total_debit" => "1250000",
               "total_credit" => "1250000",
               "warning_count" => 1
             }

      import_id = imported.id
      assert_receive {:import_updated, %{import_id: ^import_id, status: :processing}}

      assert_receive {:import_updated,
                      %{import_id: ^import_id, status: :succeeded, entry_count: 2, error_count: 0}}

      assert_audit_appended(event)
      refute_received {:audit_appended, _}
    end

    test "writes nothing when an entry is rejected after a full chunk was written", ctx do
      # 1,001 good entries fill one insert chunk before the bad one is read.
      good = Enum.flat_map(1..1001, &gl_entry("JE-#{&1}"))
      [debit, credit] = gl_entry("JE-1002")
      csv = gl_csv(good ++ [debit, %{credit | credit: "1"}])

      imported = ledger_import_fixture(ctx.preparer, ctx.engagement, csv)
      :ok = Engagements.subscribe(ctx.preparer, ctx.engagement.id)

      assert {:ok, failed} = Ledger.process_import(imported.id)

      assert failed.status == :failed
      assert failed.errors == [%{"line" => 2004, "field" => nil, "code" => "unbalanced_entry"}]
      assert failed.error_count == 1
      assert failed.entry_count == 0
      assert %DateTime{} = failed.finished_at
      assert count_rows(JournalEntry, imported.id) == 0
      assert count_rows(JournalLine, imported.id) == 0

      assert [_created, event] = audit_events(imported.id)
      assert event.action == "ledger_import.failed"
      assert {event.actor_type, event.actor_id} == {:system, "ledger.import_worker"}
      assert event.payload == %{"reason" => "validation_failed", "error_count" => 1}

      import_id = imported.id

      assert_receive {:import_updated,
                      %{import_id: ^import_id, status: :failed, entry_count: 0, error_count: 1}}

      assert_audit_appended(event)
      refute_received {:audit_appended, _}
    end

    test "returns a finished import as it is when called again", ctx do
      good = ledger_import_fixture(ctx.preparer, ctx.engagement, gl_csv(gl_entry("JE-0001")))

      [debit, credit] = gl_entry("JE-0001")

      bad =
        ledger_import_fixture(
          ctx.preparer,
          ctx.engagement,
          gl_csv([debit, %{credit | credit: "1"}])
        )

      assert {:ok, %{status: :succeeded}} = Ledger.process_import(good.id)
      assert {:ok, %{status: :failed}} = Ledger.process_import(bad.id)
      :ok = Engagements.subscribe(ctx.preparer, ctx.engagement.id)

      assert {:ok, %{status: :succeeded, entry_count: 1}} = Ledger.process_import(good.id)
      assert {:ok, %{status: :failed, error_count: 1}} = Ledger.process_import(bad.id)

      assert count_rows(JournalEntry, good.id) == 1
      assert length(audit_events(good.id)) == 2
      assert length(audit_events(bad.id)) == 2
      refute_receive {:import_updated, _}
      refute_received {:audit_appended, _}
    end

    test "starts over an import left processing by an attempt that crashed", ctx do
      imported = ledger_import_fixture(ctx.preparer, ctx.engagement, gl_csv(gl_entry("JE-0001")))
      Repo.update!(Ecto.Changeset.change(imported, status: :processing))

      assert {:ok, %{status: :succeeded, entry_count: 1}} = Ledger.process_import(imported.id)
    end

    @tag :capture_log
    test "fails the import when the stored file is gone", ctx do
      imported = ledger_import_fixture(ctx.preparer, ctx.engagement, gl_csv(gl_entry("JE-0001")))
      File.rm!(stored_path(imported))
      :ok = Engagements.subscribe(ctx.preparer, ctx.engagement.id)

      assert {:ok, failed} = Ledger.process_import(imported.id)
      assert failed.status == :failed
      assert failed.errors == [] and failed.error_count == 0

      assert [_created, event] = audit_events(imported.id)
      assert event.payload == %{"reason" => "file_missing", "error_count" => 0}
      assert_audit_appended(event)
      refute_received {:audit_appended, _}
    end

    test "returns :not_found for unknown and malformed ids", ctx do
      :ok = Engagements.subscribe(ctx.preparer, ctx.engagement.id)
      assert Ledger.process_import(Ecto.UUID.generate()) == {:error, :not_found}
      assert Ledger.process_import("not-a-uuid") == {:error, :not_found}
      refute_received {:audit_appended, _}
    end
  end

  describe "mark_import_failed/2" do
    test "fails an unfinished import and keeps the reason in the log only", ctx do
      imported = ledger_import_fixture(ctx.preparer, ctx.engagement, gl_csv(gl_entry("JE-0001")))
      :ok = Engagements.subscribe(ctx.preparer, ctx.engagement.id)

      log =
        capture_log(fn ->
          assert Ledger.mark_import_failed(imported.id, %RuntimeError{message: "internal detail"}) ==
                   :ok
        end)

      assert log =~ "internal detail"

      failed = Repo.get!(LedgerImport, imported.id)
      assert failed.status == :failed
      assert failed.errors == [] and failed.error_count == 0

      assert [_created, event] = audit_events(imported.id)
      assert event.action == "ledger_import.failed"
      assert event.payload == %{"reason" => "worker_failed", "error_count" => 0}

      import_id = imported.id
      assert_receive {:import_updated, %{import_id: ^import_id, status: :failed}}
      assert_audit_appended(event)
      refute_received {:audit_appended, _}
    end

    @tag :capture_log
    test "leaves a finished import alone", ctx do
      imported = ledger_import_fixture(ctx.preparer, ctx.engagement, gl_csv(gl_entry("JE-0001")))
      {:ok, _loaded} = Ledger.process_import(imported.id)
      :ok = Engagements.subscribe(ctx.preparer, ctx.engagement.id)

      assert Ledger.mark_import_failed(imported.id, :timeout) == :ok
      assert Repo.get!(LedgerImport, imported.id).status == :succeeded
      assert length(audit_events(imported.id)) == 2
      refute_received {:audit_appended, _}
    end

    @tag :capture_log
    test "returns :ok for unknown and malformed ids", ctx do
      :ok = Engagements.subscribe(ctx.preparer, ctx.engagement.id)
      assert Ledger.mark_import_failed(Ecto.UUID.generate(), :timeout) == :ok
      assert Ledger.mark_import_failed("not-a-uuid", :timeout) == :ok
      refute_received {:audit_appended, _}
    end
  end

  describe "list_imports/2" do
    test "lists the engagement's imports newest first for members only", ctx do
      first = ledger_import_fixture(ctx.preparer, ctx.engagement, gl_csv(gl_entry("JE-0001")))
      second = ledger_import_fixture(ctx.preparer, ctx.engagement, gl_csv(gl_entry("JE-0002")))

      other = insert_engagement(ctx.outsider.user)
      insert_member(other, ctx.outsider.user, :preparer)
      ledger_import_fixture(ctx.outsider, other, gl_csv(gl_entry("JE-0003")))

      assert Enum.map(Ledger.list_imports(ctx.preparer, ctx.engagement.id), & &1.id) ==
               [second.id, first.id]

      assert length(Ledger.list_imports(ctx.reviewer, ctx.engagement.id)) == 2
      assert Ledger.list_imports(ctx.outsider, ctx.engagement.id) == []
      assert Ledger.list_imports(ctx.preparer, "not-a-uuid") == []
    end
  end

  describe "get_import!/2 and get_entry!/2" do
    setup ctx do
      # The file lists line 2 before line 1.
      csv = gl_csv(Enum.reverse(gl_entry("JE-0001")))
      imported = ledger_import_fixture(ctx.preparer, ctx.engagement, csv)
      {:ok, _loaded} = Ledger.process_import(imported.id)
      entry = Repo.one!(from e in JournalEntry, where: e.ledger_import_id == ^imported.id)

      other = insert_engagement(ctx.outsider.user)
      insert_member(other, ctx.outsider.user, :preparer)
      other_import = ledger_import_fixture(ctx.outsider, other, gl_csv(gl_entry("JE-0002")))
      {:ok, _loaded} = Ledger.process_import(other_import.id)

      other_entry =
        Repo.one!(from e in JournalEntry, where: e.ledger_import_id == ^other_import.id)

      %{imported: imported, entry: entry, other_import: other_import, other_entry: other_entry}
    end

    test "return the record to members, with lines in line_number order", ctx do
      assert Ledger.get_import!(ctx.reviewer, ctx.imported.id).id == ctx.imported.id

      entry = Ledger.get_entry!(ctx.reviewer, ctx.entry.id)
      assert entry.id == ctx.entry.id
      assert Enum.map(entry.lines, & &1.line_number) == [1, 2]
      assert Enum.map(entry.lines, & &1.account_code) == ["51100", "10300"]
    end

    test "raise Ecto.NoResultsError for outsiders, other engagements, unknown and malformed ids",
         ctx do
      for id <- [ctx.other_import.id, Ecto.UUID.generate(), "not-a-uuid"] do
        assert_raise Ecto.NoResultsError, fn -> Ledger.get_import!(ctx.preparer, id) end
      end

      assert_raise Ecto.NoResultsError, fn ->
        Ledger.get_import!(ctx.outsider, ctx.imported.id)
      end

      assert_raise Ecto.NoResultsError, fn -> Ledger.get_import!(nil, ctx.imported.id) end

      for id <- [ctx.other_entry.id, Ecto.UUID.generate(), "not-a-uuid"] do
        assert_raise Ecto.NoResultsError, fn -> Ledger.get_entry!(ctx.preparer, id) end
      end

      assert_raise Ecto.NoResultsError, fn -> Ledger.get_entry!(ctx.outsider, ctx.entry.id) end
    end
  end

  defp assert_audit_appended(event) do
    assert_receive {:audit_appended, message}

    assert message == %{
             seq: event.seq,
             action: event.action,
             actor_type: event.actor_type,
             subject_type: "ledger_import",
             subject_id: event.subject_id,
             entry_number: nil
           }
  end
end
