defmodule Tickmark.DemoTest do
  # Not async: the demo password is global application config.
  use Tickmark.DataCase, async: false

  alias Tickmark.{Accounts, Demo}
  alias Tickmark.Engagements.Engagement
  alias Tickmark.Ledger.LedgerImport

  @password "demo password 1234"

  setup do
    previous = Application.get_env(:tickmark, :demo_password)
    Application.put_env(:tickmark, :demo_password, @password)
    on_exit(fn -> Application.put_env(:tickmark, :demo_password, previous) end)
  end

  # Inline mode runs each Oban job as soon as it is inserted, so the import
  # and the rule run are finished before seed/0 starts polling for them.
  test "seed/0 creates the demo once and gives both users the demo password" do
    assert {:ok, summary} = Oban.Testing.with_testing_mode(:inline, &Demo.seed/0)
    remove_import_files_on_exit()

    assert summary.engagement == "누리정밀 주식회사 FY2025"
    assert summary.import_status == :succeeded
    assert summary.test_run_status == :completed

    for email <- [summary.preparer, summary.reviewer] do
      assert %Accounts.User{confirmed_at: %DateTime{}} =
               Accounts.get_user_by_email_and_password(email, @password)
    end

    assert {:ok, :exists} = Demo.seed()
    assert Repo.aggregate(Engagement, :count) == 1
    assert Repo.aggregate(LedgerImport, :count) == 1
  end

  defp remove_import_files_on_exit do
    dir = Application.fetch_env!(:tickmark, :import_dir)

    paths =
      for %LedgerImport{stored_filename: name} <- Repo.all(LedgerImport),
          file <- [name, String.replace_suffix(name, ".csv", ".labels.csv")],
          do: Path.join(dir, file)

    on_exit(fn -> Enum.each(paths, &File.rm/1) end)
  end
end
