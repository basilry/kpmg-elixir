defmodule Tickmark.Demo do
  @moduledoc """
  Demo data (WBS 5.3). Synthetic only: the company and people below are made
  up, and the GL comes from the synthetic generator (domain doc 7).

  It goes through the contexts, so every step leaves its audit events, the
  same as clicking through S1-S4. Running it again does nothing once the demo
  preparer exists.

  `priv/repo/seeds.exs` calls `seed/0` in development. A release calls
  `seed_on_boot/0` from the supervision tree when `TICKMARK_SEED_ON_BOOT` is
  set, because the free host has no shell to run seeds from.
  """

  require Logger

  alias Tickmark.{Accounts, Engagements, Ledger, Repo, Testing}
  alias Tickmark.Accounts.{Scope, User}
  alias Tickmark.Ledger.LedgerImport

  @preparer_email "kim.writer@example.com"
  @reviewer_email "park.reviewer@example.com"

  # The GL import and the rule run are Oban jobs that the running app works on
  # in the background. A free instance has a tenth of a CPU, so each step gets
  # far longer than the few seconds it takes on a laptop.
  @poll_interval 500
  @wait_limit :timer.minutes(15)

  @doc """
  Creates the demo users, engagement, GL import and test run.

  Returns `{:ok, :exists}` when the demo preparer is already there, otherwise
  `{:ok, summary}`. Raises when a step fails, so a half-made demo shows up in
  the logs instead of looking finished.
  """
  def seed do
    if Accounts.get_user_by_email(@preparer_email) do
      {:ok, :exists}
    else
      {:ok, create_demo()}
    end
  end

  @doc "Runs `seed/0` and logs the outcome. Used by the boot task."
  def seed_on_boot do
    case seed() do
      {:ok, :exists} ->
        Logger.info("demo seed: demo data already exists, nothing to do")

      {:ok, summary} ->
        Logger.info(
          "demo seed: created #{summary.engagement}, GL import #{summary.import_status}, " <>
            "test run #{summary.test_run_status}"
        )
    end
  end

  defp create_demo do
    preparer = create_user(@preparer_email)
    _reviewer = create_user(@reviewer_email)
    scope = Scope.for_user(preparer)

    {:ok, engagement} =
      Engagements.create_engagement(scope, %{
        client_name: "누리정밀 주식회사",
        fiscal_year: 2025,
        period_end_date: ~D[2025-12-31],
        performance_materiality: "225000000"
      })

    {:ok, _member} = Engagements.add_member(scope, engagement, @reviewer_email, :reviewer)

    {:ok, ledger_import} = Ledger.generate_sample_import(scope, engagement)

    ledger_import =
      wait_for("GL import", fn ->
        ledger_import = Repo.get!(LedgerImport, ledger_import.id)
        if LedgerImport.finished?(ledger_import), do: ledger_import
      end)

    if ledger_import.status != :succeeded do
      raise "demo seed: GL import ended as #{ledger_import.status}"
    end

    {:ok, test_run} = Testing.start_test_run(scope, ledger_import, :all)

    test_run =
      wait_for("test run", fn ->
        test_run = Testing.get_test_run!(scope, test_run.id)
        if test_run.status != :running, do: test_run
      end)

    %{
      preparer: @preparer_email,
      reviewer: @reviewer_email,
      engagement: "#{engagement.client_name} FY#{engagement.fiscal_year}",
      import_status: ledger_import.status,
      test_run_status: test_run.status
    }
  end

  # Without a demo password the users can only log in by magic link, which
  # needs a mailer. The password is read in config/runtime.exs.
  defp create_user(email) do
    {:ok, user} = Accounts.register_user(%{email: email})
    user = user |> User.confirm_changeset() |> Repo.update!()

    case Application.get_env(:tickmark, :demo_password) do
      nil ->
        user

      password ->
        {:ok, {user, _expired_tokens}} =
          Accounts.update_user_password(user, %{password: password})

        user
    end
  end

  # Polls until `fun` returns a non-nil value.
  defp wait_for(label, fun, waited \\ 0) do
    case fun.() do
      nil when waited >= @wait_limit ->
        raise "demo seed: #{label} did not finish within #{div(@wait_limit, 60_000)} minutes"

      nil ->
        Process.sleep(@poll_interval)
        wait_for(label, fun, waited + @poll_interval)

      value ->
        value
    end
  end
end
