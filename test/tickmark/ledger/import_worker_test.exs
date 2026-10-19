defmodule Tickmark.Ledger.ImportWorkerTest do
  use Tickmark.DataCase, async: true
  use Oban.Testing, repo: Tickmark.Repo

  import Tickmark.AccountsFixtures
  import Tickmark.LedgerFixtures
  import Tickmark.SchemaFixtures

  alias Tickmark.Accounts.Scope
  alias Tickmark.Ledger.{ImportWorker, LedgerImport}

  setup do
    user = user_fixture()
    engagement = insert_engagement(user)
    insert_member(engagement, user, :preparer)
    %{engagement: engagement, scope: Scope.for_user(user)}
  end

  defp perform(import_id), do: perform_job(ImportWorker, %{"ledger_import_id" => import_id})

  test "runs on the ingest queue with 3 attempts and a 10 minute timeout" do
    job = Ecto.Changeset.apply_changes(ImportWorker.new(%{"ledger_import_id" => "id"}))

    assert job.queue == "ingest"
    assert job.max_attempts == 3
    assert ImportWorker.timeout(job) == :timer.minutes(10)
  end

  test "completes after loading the file, and again when the import is already loaded", ctx do
    imported = ledger_import_fixture(ctx.scope, ctx.engagement, gl_csv(gl_entry("JE-0001")))

    assert perform(imported.id) == :ok
    assert Repo.get!(LedgerImport, imported.id).status == :succeeded
    assert perform(imported.id) == :ok
  end

  test "cancels when the file is rejected, since a retry would fail the same way", ctx do
    [debit, credit] = gl_entry("JE-0001")
    csv = gl_csv([debit, %{credit | credit: "1"}])
    imported = ledger_import_fixture(ctx.scope, ctx.engagement, csv)

    assert perform(imported.id) == {:cancel, :import_failed}
    assert Repo.get!(LedgerImport, imported.id).status == :failed
    assert perform(imported.id) == {:cancel, :import_failed}
  end

  test "cancels when the import does not exist" do
    assert perform(Ecto.UUID.generate()) == {:cancel, :not_found}
  end
end
