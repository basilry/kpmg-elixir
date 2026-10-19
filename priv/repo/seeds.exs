# Demo data (WBS 5.3). Synthetic only: the company and people below are made
# up, and the GL comes from the synthetic generator (domain doc 7).
#
#     mix run priv/repo/seeds.exs
#
# It goes through the contexts, so every step leaves its audit events, the
# same as clicking through S1-S4. Running it again does nothing once the demo
# preparer exists.
#
# Log in at /users/log-in with a magic link (dev mailbox at /dev/mailbox). Set
# TICKMARK_DEMO_PASSWORD (12 characters or more) to also give both demo users
# that password.

alias Tickmark.{Accounts, Engagements, Ledger, Repo, Testing}
alias Tickmark.Accounts.{Scope, User}
alias Tickmark.Ledger.LedgerImport

preparer_email = "kim.writer@example.com"
reviewer_email = "park.reviewer@example.com"

# Polls until `fun` returns a non-nil value. The GL import and the rule run
# are Oban jobs, which the app started by `mix run` works on in the background.
wait_for = fn label, fun ->
  Enum.reduce_while(1..240, nil, fn _, _ ->
    case fun.() do
      nil ->
        Process.sleep(500)
        {:cont, nil}

      value ->
        {:halt, value}
    end
  end) || raise "seeds: #{label} did not finish within 2 minutes"
end

create_user = fn email ->
  {:ok, user} = Accounts.register_user(%{email: email})
  user = user |> User.confirm_changeset() |> Repo.update!()

  case System.get_env("TICKMARK_DEMO_PASSWORD") do
    nil ->
      user

    password ->
      {:ok, {user, _expired_tokens}} = Accounts.update_user_password(user, %{password: password})
      user
  end
end

if Accounts.get_user_by_email(preparer_email) do
  IO.puts("seeds: demo data already exists, nothing to do")
else
  preparer = create_user.(preparer_email)
  reviewer = create_user.(reviewer_email)
  scope = Scope.for_user(preparer)

  {:ok, engagement} =
    Engagements.create_engagement(scope, %{
      client_name: "누리정밀 주식회사",
      fiscal_year: 2025,
      period_end_date: ~D[2025-12-31],
      performance_materiality: "225000000"
    })

  {:ok, _member} = Engagements.add_member(scope, engagement, reviewer_email, :reviewer)

  {:ok, ledger_import} = Ledger.generate_sample_import(scope, engagement)

  ledger_import =
    wait_for.("GL import", fn ->
      ledger_import = Repo.get!(LedgerImport, ledger_import.id)
      if LedgerImport.finished?(ledger_import), do: ledger_import
    end)

  if ledger_import.status != :succeeded do
    raise "seeds: GL import ended as #{ledger_import.status}"
  end

  {:ok, test_run} = Testing.start_test_run(scope, ledger_import, :all)

  test_run =
    wait_for.("test run", fn ->
      test_run = Testing.get_test_run!(scope, test_run.id)
      if test_run.status != :running, do: test_run
    end)

  IO.puts("""
  seeds: demo data created
    preparer  #{preparer.email}
    reviewer  #{reviewer.email}
    engagement #{engagement.client_name} FY#{engagement.fiscal_year}
    GL import  #{ledger_import.status}
    test run   #{test_run.status}
  """)
end
