defmodule Tickmark.Engagements.PolicyTest do
  use ExUnit.Case, async: true

  alias Tickmark.Engagements.Policy

  # Mirrors the Policy table in the architecture doc 8.
  @table [
    {:view, true, true},
    {:import_ledger, true, false},
    {:start_test_run, true, false},
    {:request_triage, true, false},
    {:submit_conclusion, true, false},
    {:review_conclusion, false, true},
    {:manage_members, false, false}
  ]

  test "matches the policy table" do
    for {action, preparer?, reviewer?} <- @table do
      assert Policy.allowed?(:preparer, action) == preparer?, "preparer #{action}"
      assert Policy.allowed?(:reviewer, action) == reviewer?, "reviewer #{action}"
    end
  end

  test "unknown roles and actions are denied" do
    refute Policy.allowed?(:admin, :view)
    refute Policy.allowed?(nil, :view)
    refute Policy.allowed?(:preparer, :delete_everything)
  end
end
