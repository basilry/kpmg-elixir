# Demo data (WBS 5.3). Synthetic only. The work is in Tickmark.Demo, which a
# release also runs at boot when TICKMARK_SEED_ON_BOOT is set.
#
#     mix run priv/repo/seeds.exs
#
# Running it again does nothing once the demo preparer exists.
#
# Log in at /users/log-in with a magic link (dev mailbox at /dev/mailbox). Set
# TICKMARK_DEMO_PASSWORD (12 characters or more) to also give both demo users
# that password.

case Tickmark.Demo.seed() do
  {:ok, :exists} ->
    IO.puts("seeds: demo data already exists, nothing to do")

  {:ok, summary} ->
    IO.puts("""
    seeds: demo data created
      preparer   #{summary.preparer}
      reviewer   #{summary.reviewer}
      engagement #{summary.engagement}
      GL import  #{summary.import_status}
      test run   #{summary.test_run_status}
    """)
end
