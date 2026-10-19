defmodule Tickmark.Ledger.ImportStorageTest do
  # Not async: each test points :import_dir at its own empty directory, and
  # application env is global. ExUnit runs sync modules after the async ones,
  # so no other test sees the change.
  use Tickmark.DataCase, async: false
  use Oban.Testing, repo: Tickmark.Repo

  import Tickmark.AccountsFixtures
  import Tickmark.LedgerFixtures
  import Tickmark.SchemaFixtures

  alias Tickmark.Accounts.Scope
  alias Tickmark.Ledger

  setup do
    dir = Path.join(System.tmp_dir!(), "tickmark-imports-#{System.unique_integer([:positive])}")
    previous = Application.fetch_env!(:tickmark, :import_dir)
    Application.put_env(:tickmark, :import_dir, dir)

    on_exit(fn ->
      Application.put_env(:tickmark, :import_dir, previous)
      File.rm_rf(dir)
    end)

    preparer = user_fixture()
    reviewer = user_fixture()
    engagement = insert_engagement(preparer)
    insert_member(engagement, preparer, :preparer)
    insert_member(engagement, reviewer, :reviewer)

    %{
      dir: dir,
      engagement: engagement,
      preparer: Scope.for_user(preparer),
      reviewer: Scope.for_user(reviewer)
    }
  end

  defp stored_files(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, :enoent} -> []
    end
  end

  # Only the last byte is written, so the file takes almost no disk space.
  defp sparse_file!(size) do
    path = write_csv!("")
    {:ok, file} = File.open(path, [:write, :binary])
    {:ok, _position} = :file.position(file, size - 1)
    :ok = IO.binwrite(file, "x")
    :ok = File.close(file)
    path
  end

  test "creates the directory and keeps one copy named after stored_filename", ctx do
    path = write_csv!(gl_csv(gl_entry("JE-0001")))

    assert {:ok, imported} =
             Ledger.create_import(ctx.preparer, ctx.engagement, %{path: path, filename: "gl.csv"})

    assert stored_files(ctx.dir) == [imported.stored_filename]
    assert File.exists?(path)
  end

  test "leaves no copy behind when the file is refused or the row is invalid", ctx do
    upload = %{path: write_csv!(gl_csv(gl_entry("JE-0001"))), filename: "gl.csv"}
    assert {:error, :forbidden} = Ledger.create_import(ctx.reviewer, ctx.engagement, upload)

    too_large = %{path: sparse_file!(20_000_001), filename: "gl.csv"}

    assert {:error, :file_too_large} =
             Ledger.create_import(ctx.preparer, ctx.engagement, too_large)

    empty = %{path: write_csv!(""), filename: "gl.csv"}
    assert {:error, %Ecto.Changeset{}} = Ledger.create_import(ctx.preparer, ctx.engagement, empty)

    assert stored_files(ctx.dir) == []
    refute_enqueued(worker: Tickmark.Ledger.ImportWorker)
  end
end
