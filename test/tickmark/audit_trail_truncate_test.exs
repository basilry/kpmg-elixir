defmodule Tickmark.AuditTrailTruncateTest do
  # Not async on purpose. TRUNCATE asks for an ACCESS EXCLUSIVE lock on
  # audit_events before the trigger rejects it. Run next to async tests, it
  # queues behind any open transaction that wrote an audit event, and every
  # later insert into audit_events queues behind it, so unrelated tests time
  # out. ExUnit runs sync modules after all async ones, so nothing else holds
  # the table here.
  use Tickmark.DataCase, async: false

  test "the DB trigger rejects TRUNCATE" do
    error = assert_raise Postgrex.Error, fn -> Repo.query!("TRUNCATE audit_events") end
    assert error.postgres.message =~ "append-only table audit_events: TRUNCATE"
  end
end
