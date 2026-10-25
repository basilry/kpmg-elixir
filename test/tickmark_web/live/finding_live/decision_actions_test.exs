defmodule TickmarkWeb.FindingLive.DecisionActionsTest do
  use TickmarkWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tickmark.EngagementsFixtures
  import Tickmark.SchemaFixtures

  alias Tickmark.{Repo, Review}
  alias Tickmark.Review.{Conclusion, ReviewDecision}
  alias Tickmark.Testing.Finding

  setup :register_and_log_in_user

  setup %{scope: scope} do
    engagement = engagement_fixture(scope)
    ledger_import = insert_ledger_import(engagement, scope.user)
    run = insert_test_run(ledger_import, scope.user)
    run |> Ecto.Changeset.change(status: :completed) |> Repo.update!()
    finding = insert_finding(run, insert_journal_entry(ledger_import))
    {:ok, conclusion} = Review.submit_conclusion(scope, finding, conclusion_params())
    reviewer = member_scope_fixture(scope, engagement, :reviewer)

    %{
      engagement: engagement,
      finding: finding,
      conclusion: conclusion,
      reviewer: reviewer,
      reviewer_conn: log_in_user(build_conn(), reviewer.user),
      path: ~p"/engagements/#{engagement}/findings/#{finding}"
    }
  end

  test "approval opens a second step and cancel returns without persisting", ctx do
    {:ok, view, _html} = live(ctx.reviewer_conn, ctx.path)
    view |> element("#finding-approve") |> render_click()
    assert has_element?(view, "#approval-confirmation", "승인하시겠습니까?")

    assert has_element?(
             view,
             "#finding-confirm-approve[phx-value-conclusion-id='#{ctx.conclusion.id}']",
             "승인 확정"
           )

    refute has_element?(view, "#finding-approve")
    assert Repo.aggregate(ReviewDecision, :count) == 0
    view |> element("#finding-decision-cancel") |> render_click()
    refute has_element?(view, "#approval-confirmation")
    assert has_element?(view, "#finding-approve:not([disabled])")
    assert has_element?(view, "#finding-reject:not([disabled])")
    assert Repo.get!(Finding, ctx.finding.id).status == :concluded
  end

  test "confirming approval saves the displayed conclusion and reviewer signature", ctx do
    {:ok, view, _html} = live(ctx.reviewer_conn, ctx.path)
    view |> element("#finding-approve") |> render_click()
    view |> element("#finding-confirm-approve") |> render_click()

    decision = Repo.one!(ReviewDecision)
    assert decision.decision == :approved
    assert decision.conclusion_id == ctx.conclusion.id
    assert decision.reviewer_id == ctx.reviewer.user.id
    assert Repo.get!(Finding, ctx.finding.id).status == :approved
    assert has_element?(view, "#sign-bar[data-mode=idle]", ctx.reviewer.user.email)
    assert has_element?(view, "#sign-bar", "승인")
    assert has_element?(view, "#history-decision-#{decision.id}", "승인")
    assert has_element?(view, "#conclusion-panel[data-mode=locked]")
    refute has_element?(view, "#approval-confirmation")
    refute has_element?(view, "#finding-approve")
  end

  test "canceling rejection discards its draft and reopens an empty reason form", ctx do
    {:ok, view, _html} = live(ctx.reviewer_conn, ctx.path)
    view |> element("#finding-reject") |> render_click()

    view
    |> form("#rejection-form", review_decision: %{comment: "증빙이 부족합니다"})
    |> render_change()

    assert has_element?(view, "#rejection-character-count", "9 / 2000")
    view |> element("#finding-decision-cancel") |> render_click()
    refute has_element?(view, "#rejection-form")
    view |> element("#finding-reject") |> render_click()
    refute has_element?(view, "#rejection-comment", "증빙이 부족합니다")
    assert has_element?(view, "#rejection-character-count", "0 / 2000")
    assert Repo.aggregate(ReviewDecision, :count) == 0
  end

  test "rejection validation requires a reason and allows at most 2000 characters", ctx do
    {:ok, view, _html} = live(ctx.reviewer_conn, ctx.path)
    view |> element("#finding-reject") |> render_click()
    view |> form("#rejection-form", review_decision: %{comment: ""}) |> render_change()
    assert has_element?(view, "#rejection-form", "반려 사유 (필수)")
    assert has_element?(view, "#rejection-form", "반려 사유를 입력하세요")

    view
    |> form("#rejection-form", review_decision: %{comment: String.duplicate("가", 2001)})
    |> render_change()

    assert has_element?(view, "#rejection-character-count", "2001 / 2000")
    assert has_element?(view, "#rejection-form", "반려 사유는 2000자 이하로 입력하세요")

    view
    |> form("#rejection-form", review_decision: %{comment: String.duplicate("가", 2000)})
    |> render_change()

    assert has_element?(view, "#rejection-character-count", "2000 / 2000")
    refute has_element?(view, "#rejection-form", "반려 사유는 2000자 이하로 입력하세요")
    assert Repo.aggregate(ReviewDecision, :count) == 0
  end

  test "confirming an empty or oversized rejection keeps the form with field errors", ctx do
    {:ok, view, _html} = live(ctx.reviewer_conn, ctx.path)
    view |> element("#finding-reject") |> render_click()

    for comment <- ["", "   ", String.duplicate("가", 2001)] do
      view |> form("#rejection-form", review_decision: %{comment: comment}) |> render_submit()
      assert has_element?(view, "#rejection-form")
      assert has_element?(view, "#rejection-form .text-error")
    end

    assert Repo.aggregate(ReviewDecision, :count) == 0
    assert Repo.get!(Finding, ctx.finding.id).status == :concluded
  end

  test "confirming rejection saves its reason in the signature and history", ctx do
    {:ok, view, _html} = live(ctx.reviewer_conn, ctx.path)
    view |> element("#finding-reject") |> render_click()

    assert has_element?(
             view,
             "#finding-confirm-reject[phx-value-conclusion-id='#{ctx.conclusion.id}']"
           )

    comment = "급여대장과 대사한 결과를 제출하세요"
    view |> form("#rejection-form", review_decision: %{comment: comment}) |> render_submit()

    decision = Repo.one!(ReviewDecision)
    assert decision.decision == :rejected
    assert decision.comment == comment
    assert decision.conclusion_id == ctx.conclusion.id
    assert Repo.get!(Finding, ctx.finding.id).status == :rejected
    assert has_element?(view, "#sign-bar[data-mode=idle]", "반려")
    assert has_element?(view, "#sign-bar", comment)
    assert has_element?(view, "#sign-bar", ctx.reviewer.user.email)
    assert has_element?(view, "#history-decision-#{decision.id}", comment)
    refute has_element?(view, "#rejection-form")
  end

  test "an old approval ID is stale even after PubSub updates the server assign", ctx do
    {:ok, view, _html} = live(ctx.reviewer_conn, ctx.path)
    view |> element("#finding-approve") |> render_click()

    assert has_element?(
             view,
             "#finding-confirm-approve[phx-value-conclusion-id='#{ctx.conclusion.id}']"
           )

    {:ok, latest} = Review.submit_conclusion(ctx.scope, ctx.finding, conclusion_params("새 결론"))
    assert has_element?(view, "#conclusion-summary", latest.comment)

    render_click(view, "confirm_approve", %{"conclusion-id" => ctx.conclusion.id})

    assert has_element?(view, "#flash-error", "작성자가 새 결론을 제출했습니다. 최신 결론을 확인한 뒤 다시 결정하세요.")
    assert has_element?(view, "#sign-bar[data-mode=idle]")
    refute has_element?(view, "#approval-confirmation")
    assert Repo.get!(Finding, ctx.finding.id).status == :concluded
    assert Repo.aggregate(ReviewDecision, :count) == 0
  end

  test "an old rejection ID closes the form with the stale message", ctx do
    {:ok, view, _html} = live(ctx.reviewer_conn, ctx.path)
    view |> element("#finding-reject") |> render_click()
    {:ok, latest} = Review.submit_conclusion(ctx.scope, ctx.finding, conclusion_params("새 결론"))
    assert has_element?(view, "#conclusion-summary", latest.comment)

    render_submit(view, "confirm_reject", %{
      "conclusion-id" => ctx.conclusion.id,
      "review_decision" => %{"comment" => "오래된 결론의 반려 사유"}
    })

    assert has_element?(view, "#flash-error", "작성자가 새 결론을 제출했습니다. 최신 결론을 확인한 뒤 다시 결정하세요.")
    refute has_element?(view, "#rejection-form")
    assert has_element?(view, "#sign-bar[data-mode=idle]")
    assert Repo.get!(Finding, ctx.finding.id).status == :concluded
    assert Repo.aggregate(ReviewDecision, :count) == 0
  end

  test "an already decided conclusion refreshes the signature with invalid_state", ctx do
    {:ok, view, _html} = live(ctx.reviewer_conn, ctx.path)
    view |> element("#finding-approve") |> render_click()

    {:ok, _decision} =
      Review.decide(ctx.reviewer, ctx.finding, ctx.conclusion.id, %{"decision" => "approved"})

    render_click(view, "confirm_approve", %{"conclusion-id" => ctx.conclusion.id})
    assert has_element?(view, "#flash-error", "이 항목은 이미 처리되었습니다. 최신 상태로 다시 불러왔습니다.")
    assert has_element?(view, "#sign-bar[data-mode=idle]", "승인")
    refute has_element?(view, "#approval-confirmation")
    assert Repo.aggregate(ReviewDecision, :count) == 1
  end

  test "preparer review buttons are disabled and forged final decisions are forbidden", ctx do
    {:ok, view, _html} = live(ctx.conn, ctx.path)
    assert has_element?(view, "#finding-approve[disabled]")
    assert has_element?(view, "#finding-reject[disabled]")

    render_click(view, "start_approve")
    render_click(view, "start_reject")
    refute has_element?(view, "#approval-confirmation")
    refute has_element?(view, "#rejection-form")

    render_click(view, "confirm_approve", %{"conclusion-id" => ctx.conclusion.id})
    assert has_element?(view, "#flash-error", "승인, 반려할 권한이 없습니다.")

    render_submit(view, "confirm_reject", %{
      "conclusion-id" => ctx.conclusion.id,
      "review_decision" => %{"comment" => "직접 보낸 사유"}
    })

    assert has_element?(view, "#flash-error", "승인, 반려할 권한이 없습니다.")
    assert has_element?(view, "#sign-bar[data-mode=idle]")
    assert Repo.aggregate(ReviewDecision, :count) == 0
  end

  test "a reviewer with a historical own conclusion cannot review it through a final event",
       ctx do
    # A schema fixture represents a conclusion from before this user's role changed.
    own = insert_conclusion(ctx.finding, ctx.reviewer.user)
    {:ok, view, _html} = live(ctx.reviewer_conn, ctx.path)
    assert has_element?(view, "#finding-approve[disabled]")
    assert has_element?(view, "#sign-bar-reason", "본인이 제출한 결론은 승인, 반려할 수 없습니다.")

    render_click(view, "confirm_approve", %{"conclusion-id" => own.id})
    assert has_element?(view, "#flash-error", "본인이 제출한 결론은 승인, 반려할 수 없습니다.")
    assert has_element?(view, "#sign-bar[data-mode=idle]")
    refute has_element?(view, "#approval-confirmation")
    assert Repo.aggregate(ReviewDecision, :count) == 0
    assert Repo.get!(Finding, ctx.finding.id).status == :concluded
    assert Repo.aggregate(Conclusion, :count) == 2
  end

  defp conclusion_params(comment \\ "증빙 확인 결과"),
    do: %{"outcome" => "needs_follow_up", "comment" => comment}
end
