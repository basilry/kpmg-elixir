defmodule TickmarkWeb.FindingLive.RealtimeActionsTest do
  use TickmarkWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tickmark.EngagementsFixtures
  import Tickmark.SchemaFixtures

  alias Tickmark.{Engagements, Repo, Review}
  alias Tickmark.Review.Conclusion

  setup :register_and_log_in_user

  setup %{scope: scope} do
    engagement = engagement_fixture(scope)
    ledger_import = insert_ledger_import(engagement, scope.user)
    run = insert_test_run(ledger_import, scope.user)
    run |> Ecto.Changeset.change(status: :completed) |> Repo.update!()
    finding = insert_finding(run, insert_journal_entry(ledger_import))

    {:ok, conclusion} =
      Review.submit_conclusion(scope, finding, %{
        "outcome" => "needs_follow_up",
        "comment" => "처음 결론"
      })

    reviewer = member_scope_fixture(scope, engagement, :reviewer)

    %{
      engagement: engagement,
      finding: finding,
      conclusion: conclusion,
      reviewer_conn: log_in_user(build_conn(), reviewer.user),
      path: ~p"/engagements/#{engagement}/findings/#{finding}"
    }
  end

  test "another preparer LiveView resubmission closes the reviewer's approval confirmation",
       ctx do
    {:ok, preparer_view, _html} = live(ctx.conn, ctx.path)
    {:ok, reviewer_view, _html} = live(ctx.reviewer_conn, ctx.path)
    reviewer_view |> element("#finding-approve") |> render_click()
    assert has_element?(reviewer_view, "#approval-confirmation")

    preparer_view
    |> form("#conclusion-form", conclusion: %{outcome: "exception", comment: "재검토 후 새 결론"})
    |> render_submit()

    latest = Repo.get_by!(Conclusion, finding_id: ctx.finding.id, comment: "재검토 후 새 결론")
    assert has_element?(reviewer_view, "#conclusion-summary", latest.comment)
    assert has_element?(reviewer_view, "#history-conclusion-#{latest.id}", latest.comment)
    assert has_element?(reviewer_view, "#history-conclusion-#{ctx.conclusion.id}", "처음 결론")

    assert has_element?(
             reviewer_view,
             "#conclusion-notice",
             "작성자가 결론을 다시 제출했습니다. 최신 결론을 확인한 뒤 결정하세요."
           )

    assert has_element?(reviewer_view, "#sign-bar[data-mode=idle]")
    refute has_element?(reviewer_view, "#approval-confirmation")
    reviewer_view |> element("#finding-approve") |> render_click()

    assert has_element?(
             reviewer_view,
             "#finding-confirm-approve[phx-value-conclusion-id='#{latest.id}']"
           )
  end

  test "a new conclusion also closes the reviewer's rejection form and resets its reason", ctx do
    {:ok, preparer_view, _html} = live(ctx.conn, ctx.path)
    {:ok, reviewer_view, _html} = live(ctx.reviewer_conn, ctx.path)
    reviewer_view |> element("#finding-reject") |> render_click()

    reviewer_view
    |> form("#rejection-form", review_decision: %{comment: "이전 결론을 보며 쓰던 사유"})
    |> render_change()

    preparer_view
    |> form("#conclusion-form", conclusion: %{outcome: "no_exception", comment: "추가 확인 후 결론"})
    |> render_submit()

    assert has_element?(reviewer_view, "#conclusion-summary", "추가 확인 후 결론")
    refute has_element?(reviewer_view, "#rejection-form")
    assert has_element?(reviewer_view, "#conclusion-notice", "최신 결론을 확인한 뒤 결정하세요.")
    reviewer_view |> element("#finding-reject") |> render_click()
    assert has_element?(reviewer_view, "#rejection-character-count", "0 / 2000")
    refute has_element?(reviewer_view, "#rejection-comment", "이전 결론을 보며 쓰던 사유")
  end

  test "another preparer's submission preserves the local draft and its validation errors", ctx do
    other_preparer = member_scope_fixture(ctx.scope, ctx.engagement, :preparer)
    {:ok, draft_view, _html} = live(ctx.conn, ctx.path)
    conn = log_in_user(build_conn(), other_preparer.user)
    {:ok, submitting_view, _html} = live(conn, ctx.path)

    draft_view
    |> form("#conclusion-form", conclusion: %{comment: "작성 중인 판단"})
    |> render_change()

    assert has_element?(draft_view, "#conclusion-outcome-errors", "판단을 선택하세요")

    submitting_view
    |> form("#conclusion-form", conclusion: %{outcome: "exception", comment: "다른 작성자의 결론"})
    |> render_submit()

    assert has_element?(draft_view, "#conclusion-notice", "방금 결론을 제출했습니다. 제출하면 새 결론으로 남습니다.")
    assert has_element?(draft_view, "#conclusion-comment", "작성 중인 판단")
    assert has_element?(draft_view, "#conclusion-character-count", "8 / 2000")
    assert has_element?(draft_view, "#conclusion-outcome-errors", "판단을 선택하세요")
    refute has_element?(draft_view, "#conclusion-form input[type=radio][checked]")
    assert Repo.aggregate(Conclusion, :count) == 2
  end

  test "an AI-only update resets the review step without inventing a new-conclusion warning",
       ctx do
    {:ok, view, _html} = live(ctx.reviewer_conn, ctx.path)
    view |> element("#finding-approve") |> render_click()
    triage = insert_ai_triage(ctx.finding)
    ctx.finding |> Ecto.Changeset.change(triage_status: :succeeded) |> Repo.update!()
    Engagements.broadcast(ctx.engagement.id, {:finding_updated, %{finding_id: ctx.finding.id}})

    assert has_element?(view, "#ai-triage-result", triage.rationale)
    assert has_element?(view, "#sign-bar[data-mode=idle]")
    refute has_element?(view, "#approval-confirmation")
    refute has_element?(view, "#conclusion-notice")
  end

  test "another finding's update leaves the current approval confirmation open", ctx do
    {:ok, view, _html} = live(ctx.reviewer_conn, ctx.path)
    view |> element("#finding-approve") |> render_click()

    Engagements.broadcast(
      ctx.engagement.id,
      {:finding_updated, %{finding_id: Ecto.UUID.generate()}}
    )

    assert has_element?(view, "#approval-confirmation")
    refute has_element?(view, "#conclusion-notice")
  end
end
