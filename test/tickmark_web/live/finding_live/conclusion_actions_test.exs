defmodule TickmarkWeb.FindingLive.ConclusionActionsTest do
  use TickmarkWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tickmark.EngagementsFixtures
  import Tickmark.SchemaFixtures

  alias Tickmark.{Engagements, Repo, Review}
  alias Tickmark.Review.Conclusion
  alias Tickmark.Testing.Finding

  setup :register_and_log_in_user

  setup %{scope: scope} do
    engagement = engagement_fixture(scope)
    ledger_import = insert_ledger_import(engagement, scope.user)
    run = insert_test_run(ledger_import, scope.user)
    run |> Ecto.Changeset.change(status: :completed) |> Repo.update!()
    finding = insert_finding(run, insert_journal_entry(ledger_import))
    reviewer = member_scope_fixture(scope, engagement, :reviewer)

    %{
      engagement: engagement,
      ledger_import: ledger_import,
      run: run,
      finding: finding,
      reviewer: reviewer,
      path: ~p"/engagements/#{engagement}/findings/#{finding}"
    }
  end

  test "submission appends the conclusion, refreshes history and resets the draft", ctx do
    {:ok, view, _html} = live(ctx.conn, ctx.path)
    params = %{outcome: "needs_follow_up", comment: "증빙을 요청했습니다"}
    view |> form("#conclusion-form", conclusion: params) |> render_change()
    assert has_element?(view, "#conclusion-character-count", "10 / 2000")
    view |> form("#conclusion-form", conclusion: params) |> render_submit()

    conclusion = Repo.one!(Conclusion)
    assert conclusion.comment == params.comment
    assert conclusion.outcome == :needs_follow_up
    assert conclusion.ai_triage_id == nil
    assert conclusion.preparer_id == ctx.scope.user.id
    assert Repo.get!(Finding, ctx.finding.id).status == :concluded
    assert has_element?(view, "#flash-info", "결론을 제출했습니다. 검토자에게 검토 대기로 보입니다.")
    assert has_element?(view, "#finding-review-status", "검토 대기")
    assert has_element?(view, "#history-conclusion-#{conclusion.id}", params.comment)
    assert has_element?(view, "#conclusion-character-count", "0 / 2000")
    refute has_element?(view, "#conclusion-form input[type=radio][checked]")
    refute has_element?(view, "#conclusion-comment", params.comment)
    refute has_element?(view, "#conclusion-notice")
  end

  test "a blank submission shows Korean field errors without changing stored state", ctx do
    {:ok, view, _html} = live(ctx.conn, ctx.path)
    view |> form("#conclusion-form", conclusion: %{comment: ""}) |> render_submit()

    assert has_element?(view, "#conclusion-outcome-errors", "판단을 선택하세요")
    assert has_element?(view, "#conclusion-form", "코멘트를 입력하세요 (1-2000자)")
    refute has_element?(view, "#conclusion-form", "필수 입력 항목입니다.")
    assert Repo.aggregate(Conclusion, :count) == 0
    assert Repo.get!(Finding, ctx.finding.id).status == :open
  end

  test "an oversized submission preserves the draft and its error", ctx do
    {:ok, view, _html} = live(ctx.conn, ctx.path)
    comment = String.duplicate("가", 2001)

    view
    |> form("#conclusion-form", conclusion: %{outcome: "exception", comment: comment})
    |> render_submit()

    assert has_element?(view, "#conclusion-form", "코멘트를 입력하세요 (1-2000자)")
    assert has_element?(view, "#conclusion-character-count", "2001 / 2000")
    assert has_element?(view, "#conclusion-outcome-exception[checked]")
    assert Repo.aggregate(Conclusion, :count) == 0
  end

  test "both roles see an approved finding locked and a forged submission is refused", ctx do
    {:ok, conclusion} = Review.submit_conclusion(ctx.scope, ctx.finding, conclusion_params())

    {:ok, _decision} =
      Review.decide(ctx.reviewer, ctx.finding, conclusion.id, %{"decision" => "approved"})

    for conn <- [ctx.conn, log_in_user(build_conn(), ctx.reviewer.user)] do
      {:ok, view, _html} = live(conn, ctx.path)
      assert has_element?(view, "#conclusion-panel[data-mode=locked]")
      refute has_element?(view, "#conclusion-form")
      refute has_element?(view, "#finding-approve")
      refute has_element?(view, "#finding-reject")
    end

    {:ok, view, _html} = live(ctx.conn, ctx.path)
    render_submit(view, "submit", %{"conclusion" => conclusion_params()})
    assert has_element?(view, "#flash-error", "승인된 항목은 수정할 수 없습니다.")
    assert Repo.aggregate(Conclusion, :count) == 1
    assert Repo.get!(Finding, ctx.finding.id).status == :approved
  end

  test "a reviewer has no submit form and direct submission remains forbidden", ctx do
    conn = log_in_user(build_conn(), ctx.reviewer.user)
    {:ok, view, _html} = live(conn, ctx.path)
    refute has_element?(view, "#conclusion-submit")
    assert has_element?(view, "#conclusion-panel[data-mode=read_only]")

    render_submit(view, "submit", %{"conclusion" => conclusion_params()})
    assert has_element?(view, "#flash-error", "결론을 제출할 권한이 없습니다.")
    assert Repo.aggregate(Conclusion, :count) == 0
  end

  test "a manipulated triage from another finding is refused beside its field", ctx do
    other_finding = insert_finding(ctx.run, insert_journal_entry(ctx.ledger_import))
    triage = insert_ai_triage(other_finding)
    {:ok, view, _html} = live(ctx.conn, ctx.path)

    render_submit(view, "submit", %{
      "conclusion" => Map.put(conclusion_params(), "ai_triage_id", triage.id)
    })

    assert has_element?(view, "#conclusion-ai-triage-errors", "화면의 AI 제안을 다시 확인하세요")
    assert Repo.aggregate(Conclusion, :count) == 0
    assert Repo.get!(Finding, ctx.finding.id).status == :open
  end

  test "the suggestion rendered in the card is saved with the conclusion", ctx do
    triage = insert_ai_triage(ctx.finding)
    set_triage_succeeded(ctx.finding)
    {:ok, view, _html} = live(ctx.conn, ctx.path)
    assert has_element?(view, "#ai-triage-result", triage.rationale)
    assert has_element?(view, "#conclusion-ai-triage-id[value='#{triage.id}']")

    view |> form("#conclusion-form", conclusion: conclusion_params()) |> render_submit()
    assert Repo.one!(Conclusion).ai_triage_id == triage.id
  end

  test "a click sent from the old DOM retains its triage ID after server refresh", ctx do
    seen = insert_ai_triage(ctx.finding)
    set_triage_succeeded(ctx.finding)
    {:ok, view, _html} = live(ctx.conn, ctx.path)
    assert has_element?(view, "#conclusion-ai-triage-id[value='#{seen.id}']")
    newer = insert_ai_triage(ctx.finding, %{input_hash: String.duplicate("b", 64)})

    Engagements.broadcast(ctx.engagement.id, {:finding_updated, %{finding_id: ctx.finding.id}})
    assert has_element?(view, "#conclusion-ai-triage-id[value='#{newer.id}']")

    render_submit(view, "submit", %{
      "conclusion" => Map.put(conclusion_params(), "ai_triage_id", seen.id)
    })

    assert Repo.one!(Conclusion).ai_triage_id == seen.id
  end

  test "a hidden minor-hit suggestion is not linked to a conclusion", ctx do
    insert_ai_triage(ctx.finding)
    ctx.finding |> Ecto.Changeset.change(score: 20, triage_status: :succeeded) |> Repo.update!()
    {:ok, view, _html} = live(ctx.conn, ctx.path)
    assert has_element?(view, "#ai-triage-minor")
    refute has_element?(view, "#ai-triage-result")
    assert has_element?(view, "#conclusion-ai-triage-id[value='']")

    view |> form("#conclusion-form", conclusion: conclusion_params()) |> render_submit()
    assert Repo.one!(Conclusion).ai_triage_id == nil
  end

  test "late validation cannot pair a new card with the old form's triage reference", ctx do
    seen = insert_ai_triage(ctx.finding)
    set_triage_succeeded(ctx.finding)
    {:ok, view, _html} = live(ctx.conn, ctx.path)
    assert has_element?(view, "#conclusion-ai-triage-id[value='#{seen.id}']")

    newer =
      insert_ai_triage(ctx.finding, %{
        input_hash: String.duplicate("b", 64),
        rationale: "새 제안의 근거"
      })

    Engagements.broadcast(ctx.engagement.id, {:finding_updated, %{finding_id: ctx.finding.id}})
    assert has_element?(view, "#ai-triage-result", newer.rationale)

    render_change(view, "validate", %{
      "conclusion" => Map.put(conclusion_params(), "ai_triage_id", seen.id)
    })

    assert has_element?(view, "#conclusion-ai-triage-id[value='#{newer.id}']")
    view |> form("#conclusion-form", conclusion: conclusion_params()) |> render_submit()
    assert Repo.one!(Conclusion).ai_triage_id == newer.id
  end

  test "resubmitting a rejected finding keeps its old conclusion and decision", ctx do
    {:ok, old} = Review.submit_conclusion(ctx.scope, ctx.finding, conclusion_params())

    {:ok, decision} =
      Review.decide(ctx.reviewer, ctx.finding, old.id, %{
        "decision" => "rejected",
        "comment" => "추가 증빙을 확인하세요"
      })

    {:ok, view, _html} = live(ctx.conn, ctx.path)
    assert has_element?(view, "#conclusion-rejection", decision.comment)

    view
    |> form("#conclusion-form", conclusion: %{outcome: "no_exception", comment: "추가 증빙 확인 완료"})
    |> render_submit()

    assert Repo.get!(Finding, ctx.finding.id).status == :concluded
    assert Repo.aggregate(Conclusion, :count) == 2
    assert has_element?(view, "#history-conclusion-#{old.id}")
    assert has_element?(view, "#history-decision-#{decision.id}", decision.comment)
    assert has_element?(view, "#finding-review-status", "검토 대기")
    refute has_element?(view, "#conclusion-rejection")
  end

  defp conclusion_params, do: %{"outcome" => "needs_follow_up", "comment" => "증빙 확인 결과"}

  defp set_triage_succeeded(finding),
    do: finding |> Ecto.Changeset.change(triage_status: :succeeded) |> Repo.update!()
end
