defmodule Tickmark.Engagements.Policy do
  @moduledoc """
  Which engagement role may do what. Pure functions, no DB access.

  Anything not listed is denied, including unknown actions. `:manage_members`
  is false for every role because only the engagement creator may manage
  members; `Engagements.authorize/3` checks that against `created_by_id`.
  """

  @type role :: :preparer | :reviewer
  @type action ::
          :view
          | :import_ledger
          | :start_test_run
          | :request_triage
          | :submit_conclusion
          | :review_conclusion
          | :manage_members

  @preparer_actions [:view, :import_ledger, :start_test_run, :request_triage, :submit_conclusion]
  @reviewer_actions [:view, :review_conclusion]

  @spec allowed?(role(), action()) :: boolean()
  def allowed?(:preparer, action), do: action in @preparer_actions
  def allowed?(:reviewer, action), do: action in @reviewer_actions
  def allowed?(_role, _action), do: false
end
