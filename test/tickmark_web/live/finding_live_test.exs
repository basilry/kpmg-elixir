defmodule TickmarkWeb.FindingLiveTest do
  use TickmarkWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tickmark.AccountsFixtures
  import Tickmark.EngagementsFixtures
  import Tickmark.SchemaFixtures

  alias Tickmark.{Engagements, Repo}
  alias Tickmark.Ledger.JournalLine
  alias Tickmark.Review.{Conclusion, ReviewDecision}
  alias Tickmark.Testing.RuleResult
  alias Tickmark.Triage.AiTriage

  setup :register_and_log_in_user

  setup %{scope: scope} do
    engagement = engagement_fixture(scope)
    ledger_import = insert_ledger_import(engagement, scope.user)

    run =
      insert_test_run(ledger_import, scope.user, %{
        rule_count: 3,
        started_at: ~U[2026-10-19 01:02:04.000000Z]
      })
      |> Ecto.Changeset.change(status: :completed)
      |> Repo.update!()

    entry =
      insert_journal_entry(ledger_import, %{
        entry_number: "JE-000123",
        posting_date: ~D[2025-12-30],
        document_date: ~D[2025-12-24],
        entered_at: ~N[2025-12-30 17:42:10],
        fiscal_period: 12,
        entered_by: "acct03",
        approved_by: "acct03",
        counterparty: "V012",
        total_debit: Decimal.new("40000000"),
        total_credit: Decimal.new("40000000")
      })

    credit_line = insert_line(entry, 2, "1020", "보통예금", "0", "40000000")
    debit_line = insert_line(entry, 1, "1310", "선급금", "40000000", "0")

    finding =
      insert_finding(run, entry, %{
        score: 55,
        hit_count: 3,
        rule_ids: ["approval_control_gap", "period_end_manual", "round_amount"]
      })

    approval =
      insert_hit(run, entry, "approval_control_gap", 25, "입력자가 직접 승인한 수기 전표", %{
        "entered_by" => "acct03",
        "approved_by" => "acct03"
      })

    period =
      insert_hit(run, entry, "period_end_manual", 20, "결산일 직전 수기 전표", %{
        "posting_date" => "2025-12-30"
      })

    round =
      insert_hit(run, entry, "round_amount", 10, "기준 금액 이상인 라운드 금액 수기 전표", %{
        "entry_amount" => "40000000",
        "round_unit" => "1000000"
      })

    %{
      engagement: engagement,
      ledger_import: ledger_import,
      run: run,
      entry: entry,
      finding: finding,
      debit_line: debit_line,
      credit_line: credit_line,
      hits: [round, period, approval]
    }
  end

  test "a non-member sees the same 404 as a missing finding", ctx do
    outsider = user_fixture()
    conn = log_in_user(build_conn(), outsider)

    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/engagements/#{ctx.engagement}/findings/#{ctx.finding}")
    end

    assert_error_sent 404, fn ->
      get(conn, ~p"/engagements/#{ctx.engagement}/findings/#{ctx.finding}")
    end

    for id <- [Ecto.UUID.generate(), "not-a-uuid"] do
      assert_raise Ecto.NoResultsError, fn ->
        live(ctx.conn, ~p"/engagements/#{ctx.engagement}/findings/#{id}")
      end
    end
  end

  test "a visible finding cannot be opened under a different engagement URL", ctx do
    other = engagement_fixture(ctx.scope)

    assert_raise Ecto.NoResultsError, fn ->
      live(ctx.conn, ~p"/engagements/#{other}/findings/#{ctx.finding}")
    end
  end

  test "shows the header, original facts, ordered entry lines, rule evidence and score", ctx do
    {:ok, view, _html} = open_finding(ctx)
    assert has_element?(view, "#finding-header h1", "JE-000123")
    assert has_element?(view, "#finding-header [aria-label='점수 55, 상']")
    assert has_element?(view, "#finding-conclusion-status", "미판단")
    assert has_element?(view, "#finding-review-status", "검토 전")

    assert has_element?(
             view,
             "#finding-breadcrumb a[href='/engagements/#{ctx.engagement.id}/runs/#{ctx.run.id}']",
             "테스트 실행 2026-10-19 10:02"
           )

    assert has_element?(view, "#entry-facts", "2025-12-30")
    assert has_element?(view, "#entry-facts", "2025-12-24")
    assert has_element?(view, "#entry-facts", "2025-12-30 17:42:10")
    assert has_element?(view, "#entry-facts", "수기")
    assert has_element?(view, "#entry-self-approved", "입력자와 같음")
    assert has_element?(view, "#entry-counterparty", "V012")
    assert has_element?(view, "#entry-description", "선급금 지급")

    assert element_ids(view, "#entry-line-rows > tr") ==
             Enum.map([ctx.debit_line, ctx.credit_line], &"entry-line-#{&1.id}")

    assert has_element?(view, "#entry-lines", "1310 선급금")
    assert has_element?(view, "#entry-lines-total", "차대 일치")
    assert has_element?(view, "#entry-lines-total td", "40,000,000")
    assert has_element?(view, "#entry-line-#{ctx.debit_line.id} td .sr-only", "0")
    assert element_ids(view, "#rule-hit-rows > li") == Enum.map(ctx.hits, &"rule-hit-#{&1.id}")
    assert has_element?(view, "#rule-hits", "승인 통제 이탈")
    assert has_element?(view, "#rule-hits", "입력자가 직접 승인한 수기 전표")
    assert has_element?(view, "#rule-hits details:not([open])", "근거 값")
    assert has_element?(view, "#rule-hits details", "approved_by")
    assert has_element?(view, "#finding-score-formula", "점수 55 = 10 + 20 + 25")
    assert has_element?(view, "#history-empty", "아직 결론이 없습니다.")
  end

  test "shows the score cap instead of claiming a sum above 100 is equal to 100", ctx do
    set_finding(ctx.finding, score: 100)
    insert_hit(ctx.run, ctx.entry, "weekend_holiday_posting", 30, "합성 근거", %{})
    insert_hit(ctx.run, ctx.entry, "off_hours_entry", 30, "합성 근거", %{})
    {:ok, view, _html} = open_finding(ctx)

    assert has_element?(
             view,
             "#finding-score-formula",
             "점수 100 = min(100, 30 + 30 + 10 + 20 + 25)"
           )
  end

  test "the top bar links back to the engagement and its audit log", ctx do
    {:ok, view, _html} = open_finding(ctx)
    engagement_path = ~p"/engagements/#{ctx.engagement}"

    assert has_element?(
             view,
             "#topbar-engagement[href='#{engagement_path}']",
             ctx.engagement.client_name
           )

    assert has_element?(view, "#topbar-audit[href='#{engagement_path}/audit']", "감사 로그")
    refute has_element?(view, "#topbar [aria-current=page]")
  end

  test "shows an unrequested AI card with no preselected human conclusion", ctx do
    {:ok, view, _html} = open_finding(ctx)
    assert has_element?(view, "#ai-triage-card.border-dashed", "이 제안은 판단이 아닙니다. 결론은 작성자가 입력합니다.")
    assert has_element?(view, "#ai-triage-card", "룰 근거와 전표 사실을 바탕으로")
    assert has_element?(view, "#ai-triage-request:not([disabled])", "AI 제안 요청")
    assert has_element?(view, "#conclusion-panel[data-mode=edit].border-line-strong")
    assert has_element?(view, "#conclusion-ai-triage-id[value='']")
    assert has_element?(view, "#conclusion-character-count", "0 / 2000")
    refute has_element?(view, "#conclusion-form input[type=radio][checked]")
    assert has_element?(view, "#conclusion-submit:not([disabled])", "결론 제출")
    assert has_element?(view, "#sign-bar[data-can-decide=false]", "작성자는 승인, 반려할 수 없습니다 (직무분리)")
    assert has_element?(view, "#finding-approve[disabled][aria-describedby=sign-bar-reason]")
    assert has_element?(view, "#finding-reject[disabled]")
  end

  test "queued hides an older AI result and shows analysis in progress", ctx do
    insert_ai_triage(ctx.finding, %{rationale: "이전 제안 근거"})
    set_finding(ctx.finding, triage_status: :queued)
    {:ok, view, _html} = open_finding(ctx)
    assert has_element?(view, "#ai-triage-card[aria-busy=true]", "분석 중")
    assert has_element?(view, "#finding-ai-status", "분석 중")
    assert has_element?(view, "#conclusion-ai-triage-id[value='']")
    refute has_element?(view, "#ai-triage-result")
    refute has_element?(view, "#ai-triage-request")
  end

  test "failed lets human review continue and never exposes an internal failure", ctx do
    insert_ai_triage(ctx.finding, %{stop_reason: "PRIVATE-API-FAILURE", rationale: "이전 제안 근거"})
    set_finding(ctx.finding, triage_status: :failed)
    {:ok, view, _html} = open_finding(ctx)
    assert has_element?(view, "#ai-triage-failure", "AI 제안을 받지 못했습니다. 판단은 AI 제안 없이도 진행할 수 있습니다.")
    assert has_element?(view, "#finding-ai-status", "AI 실패")
    assert has_element?(view, "#ai-triage-request:not([disabled])", "다시 요청")
    assert has_element?(view, "#conclusion-form")
    refute has_element?(view, "#ai-triage-card", "PRIVATE-API-FAILURE")
    refute has_element?(view, "#ai-triage-result")
  end

  test "succeeded shows only the newest suggestion and traces a fallback response model", ctx do
    insert_timed_triage(ctx.finding, ~U[2026-10-20 01:02:00.000000Z], %{
      input_hash: String.duplicate("b", 64),
      rationale: "새 제안의 근거",
      model: "requested-model",
      response_model: "fallback-model",
      risk_level: :high,
      missing_information: ["계약 조건"]
    })

    older =
      insert_timed_triage(ctx.finding, ~U[2026-10-20 01:01:00.000000Z], %{rationale: "이전 제안의 근거"})

    set_finding(ctx.finding, triage_status: :succeeded)
    {:ok, view, _html} = open_finding(ctx)
    assert has_element?(view, "#finding-ai-status", "높음")
    assert has_element?(view, "#ai-triage-result", "새 제안의 근거")
    refute has_element?(view, "#ai-triage-result", "이전 제안의 근거")
    assert has_element?(view, "#ai-procedures", "증빙 대사")
    assert has_element?(view, "#ai-procedures", "확보할 증거: 세금계산서")
    assert has_element?(view, "#ai-missing-information", "계약 조건")
    assert has_element?(view, "#ai-generation-info:not([open])", "생성 정보")
    assert has_element?(view, "#ai-generation-info", "requested-model")
    assert has_element?(view, "#ai-generation-info", "fallback-model")
    assert has_element?(view, "#ai-generation-info", "triage-v1")
    assert has_element?(view, "#ai-generation-info", "bbbbbbbb")

    assert has_element?(
             view,
             "#ai-generation-info time[datetime='2026-10-20T01:02:00.000000Z'][title='2026-10-20 01:02:00 UTC']",
             "2026-10-20 10:02:00"
           )

    refute has_element?(view, "#conclusion-ai-triage-id[value='#{older.id}']")
  end

  test "equal requested and response models are shown once and missing information may be empty",
       ctx do
    triage = insert_ai_triage(ctx.finding, %{risk_level: :low})
    set_finding(ctx.finding, triage_status: :succeeded)
    {:ok, view, _html} = open_finding(ctx)
    assert has_element?(view, "#ai-generation-info", triage.model)
    refute has_element?(view, "#ai-generation-info", "응답 모델")
    refute has_element?(view, "#ai-missing-information")
    assert has_element?(view, "#finding-ai-status", "낮음")
    assert has_element?(view, "#conclusion-ai-triage-id[value='#{triage.id}']")
  end

  test "minor hits explain the run's own threshold and still accept draft conclusions", ctx do
    ctx.run |> Ecto.Changeset.change(triage_threshold: 60) |> Repo.update!()
    {:ok, view, _html} = open_finding(ctx)
    assert has_element?(view, "#ai-triage-minor", "점수가 기준(60)보다 낮아 AI 트리아지 대상이 아닙니다.")
    refute has_element?(view, "#ai-triage-request")
    assert has_element?(view, "#conclusion-form")
  end

  test "history interleaves two conclusions and a rejection in chronological order", ctx do
    reviewer = user_fixture()

    newer =
      insert_timed_conclusion(ctx.finding, ctx.scope.user, ~U[2026-10-20 01:03:00.000000Z], %{
        outcome: :exception,
        comment: "새 결론"
      })

    older =
      insert_timed_conclusion(ctx.finding, ctx.scope.user, ~U[2026-10-20 01:01:00.000000Z], %{
        outcome: :needs_follow_up,
        comment: "처음 결론"
      })

    decision =
      insert_decision(
        ctx.finding,
        older,
        reviewer,
        :rejected,
        ~U[2026-10-20 01:02:00.000000Z],
        "급여대장과 대사한 뒤 다시 제출하세요"
      )

    set_finding(ctx.finding, status: :concluded)
    {:ok, view, _html} = open_finding(ctx)

    assert element_ids(view, "#history-entries > li") == [
             "history-conclusion-#{older.id}",
             "history-decision-#{decision.id}",
             "history-conclusion-#{newer.id}"
           ]

    assert has_element?(view, "#history-conclusion-#{older.id}", "처음 결론")
    assert has_element?(view, "#history-decision-#{decision.id}", reviewer.email)
    assert has_element?(view, "#history-decision-#{decision.id}", "반려")
    assert has_element?(view, "#history-decision-#{decision.id}", "급여대장과 대사한 뒤 다시 제출하세요")
    assert has_element?(view, "#finding-conclusion-status", "예외")
    assert has_element?(view, "#finding-review-status", "검토 대기")
    assert has_element?(view, "#conclusion-form")
    refute has_element?(view, "#history-empty")
  end

  test "a rejected preparer sees the rejection reason and a fresh editable form", ctx do
    conclusion = insert_conclusion(ctx.finding, ctx.scope.user)

    insert_decision(
      ctx.finding,
      conclusion,
      user_fixture(),
      :rejected,
      DateTime.utc_now(),
      "추가 증빙을 확인하세요"
    )

    set_finding(ctx.finding, status: :rejected)
    {:ok, view, _html} = open_finding(ctx)
    assert has_element?(view, "#conclusion-panel[data-mode=edit]")
    assert has_element?(view, "#conclusion-rejection", "추가 증빙을 확인하세요")
    assert has_element?(view, "#conclusion-form")
    refute has_element?(view, "#conclusion-form input[checked]")
  end

  test "a reviewer sees read-only judgement and the open-state signature reason", ctx do
    conn = reviewer_conn(ctx)
    {:ok, view, _html} = open_finding(%{ctx | conn: conn})
    assert has_element?(view, "#conclusion-panel[data-mode=read_only]")
    assert has_element?(view, "#conclusion-summary", "아직 결론이 없습니다.")
    assert has_element?(view, "#sign-bar[data-can-decide=false]", "작성자 결론이 제출되지 않았습니다")
    assert has_element?(view, "#ai-triage-request[disabled]")
    assert has_element?(view, "#ai-triage-request-help", "작성자만 요청할 수 있습니다")
    refute has_element?(view, "#conclusion-form")
  end

  test "a reviewer with another preparer's conclusion can start either decision", ctx do
    conn = reviewer_conn(ctx)

    conclusion =
      insert_conclusion(ctx.finding, ctx.scope.user, %{outcome: :exception, comment: "확인한 예외"})

    set_finding(ctx.finding, status: :concluded)
    {:ok, view, _html} = open_finding(%{ctx | conn: conn})
    assert has_element?(view, "#conclusion-summary", conclusion.comment)
    assert has_element?(view, "#conclusion-panel[data-mode=read_only]")
    assert has_element?(view, "#sign-bar[data-can-decide=true]", "작성자 판단")
    assert has_element?(view, "#finding-approve:not([disabled])")
    assert has_element?(view, "#finding-reject:not([disabled])")
    refute has_element?(view, "#conclusion-form")
  end

  test "an approved finding locks the preparer form and shows the reviewer signature", ctx do
    reviewer = user_fixture()

    conclusion =
      insert_conclusion(ctx.finding, ctx.scope.user, %{
        outcome: :no_exception,
        comment: "증빙 확인 후 이상 없음"
      })

    insert_decision(ctx.finding, conclusion, reviewer, :approved, DateTime.utc_now(), nil)
    set_finding(ctx.finding, status: :approved)
    {:ok, view, _html} = open_finding(ctx)
    assert has_element?(view, "#conclusion-panel[data-mode=locked]")
    assert has_element?(view, "#conclusion-locked", "승인된 항목은 수정할 수 없습니다")
    assert has_element?(view, "#sign-bar[data-can-decide=false]", reviewer.email)
    refute has_element?(view, "#conclusion-form")
    refute has_element?(view, "#finding-approve")
    refute has_element?(view, "#finding-reject")
  end

  test "validation uses Korean field errors and updates the comment count without writing", ctx do
    {:ok, view, _html} = open_finding(ctx)
    view |> form("#conclusion-form", conclusion: %{comment: ""}) |> render_change()
    assert has_element?(view, "#conclusion-outcome-errors", "판단을 선택하세요")
    assert has_element?(view, "#conclusion-form", "코멘트를 입력하세요 (1-2000자)")
    refute has_element?(view, "#conclusion-form", "필수 입력 항목입니다.")
    long_comment = String.duplicate("가", 2001)

    view
    |> form("#conclusion-form", conclusion: %{outcome: "exception", comment: long_comment})
    |> render_change()

    assert has_element?(view, "#conclusion-form", "코멘트를 입력하세요 (1-2000자)")
    assert has_element?(view, "#conclusion-character-count", "2001 / 2000")

    view
    |> form("#conclusion-form", conclusion: %{outcome: "needs_follow_up", comment: "증빙 요청"})
    |> render_change()

    assert has_element?(view, "#conclusion-character-count", "5 / 2000")
    assert has_element?(view, "#conclusion-outcome-needs_follow_up[checked]")
    refute has_element?(view, "#conclusion-form", "코멘트를 입력하세요 (1-2000자)")
    assert Repo.aggregate(Conclusion, :count) == 0
    assert Repo.aggregate(ReviewDecision, :count) == 0
  end

  test "same-finding updates refresh AI, badges and history while preserving the draft", ctx do
    {:ok, view, _html} = open_finding(ctx)

    view
    |> form("#conclusion-form", conclusion: %{outcome: "needs_follow_up", comment: "작성 중인 판단"})
    |> render_change()

    triage = insert_ai_triage(ctx.finding, %{risk_level: :high, rationale: "새 AI 근거"})

    conclusion =
      insert_conclusion(ctx.finding, ctx.scope.user, %{outcome: :exception, comment: "다른 탭의 제출"})

    set_finding(ctx.finding, triage_status: :succeeded, status: :concluded)
    broadcast_finding(ctx, ctx.finding.id)
    assert has_element?(view, "#finding-ai-status", "높음")
    assert has_element?(view, "#ai-triage-result", "새 AI 근거")
    assert has_element?(view, "#finding-review-status", "검토 대기")
    assert has_element?(view, "#history-conclusion-#{conclusion.id}", "다른 탭의 제출")
    assert has_element?(view, "#conclusion-notice", "방금 결론을 제출했습니다")
    assert has_element?(view, "#conclusion-comment", "작성 중인 판단")
    assert has_element?(view, "#conclusion-outcome-needs_follow_up[checked]")
    assert has_element?(view, "#conclusion-character-count", "8 / 2000")
    assert has_element?(view, "#conclusion-ai-triage-id[value='#{triage.id}']")
  end

  test "a new suggestion replaces only the displayed AI reference and retains validation errors",
       ctx do
    first = insert_timed_triage(ctx.finding, ~U[2026-10-20 01:01:00.000000Z], %{})
    set_finding(ctx.finding, triage_status: :succeeded)
    {:ok, view, _html} = open_finding(ctx)
    assert has_element?(view, "#conclusion-ai-triage-id[value='#{first.id}']")

    view
    |> form("#conclusion-form", conclusion: %{outcome: "exception", comment: ""})
    |> render_change()

    latest =
      insert_timed_triage(ctx.finding, ~U[2026-10-20 01:02:00.000000Z], %{
        input_hash: String.duplicate("b", 64),
        risk_level: :high
      })

    broadcast_finding(ctx, ctx.finding.id)
    assert has_element?(view, "#conclusion-ai-triage-id[value='#{latest.id}']")
    assert has_element?(view, "#conclusion-outcome-exception[checked]")
    assert has_element?(view, "#conclusion-form", "코멘트를 입력하세요 (1-2000자)")
  end

  test "an approval update locks an open draft and appends the reviewer signature", ctx do
    {:ok, view, _html} = open_finding(ctx)

    view
    |> form("#conclusion-form", conclusion: %{outcome: "needs_follow_up", comment: "작성 중인 판단"})
    |> render_change()

    conclusion = insert_conclusion(ctx.finding, ctx.scope.user)
    set_finding(ctx.finding, status: :concluded)
    broadcast_finding(ctx, ctx.finding.id)
    assert has_element?(view, "#conclusion-notice")
    reviewer = user_fixture()

    decision =
      insert_decision(ctx.finding, conclusion, reviewer, :approved, DateTime.utc_now(), nil)

    set_finding(ctx.finding, status: :approved)
    broadcast_finding(ctx, ctx.finding.id)
    assert has_element?(view, "#finding-review-status", "승인")
    assert has_element?(view, "#conclusion-panel[data-mode=locked]")
    assert has_element?(view, "#history-decision-#{decision.id}", "승인")
    assert has_element?(view, "#sign-bar", reviewer.email)
    refute has_element?(view, "#conclusion-form")
    refute has_element?(view, "#conclusion-notice")
  end

  test "a reviewer's latest conclusion summary updates and cannot be changed by validate", ctx do
    conn = reviewer_conn(ctx)
    insert_conclusion(ctx.finding, ctx.scope.user, %{comment: "검토 중인 결론"})
    set_finding(ctx.finding, status: :concluded)
    {:ok, view, _html} = open_finding(%{ctx | conn: conn})
    assert has_element?(view, "#conclusion-summary", "검토 중인 결론")
    insert_conclusion(ctx.finding, ctx.scope.user, %{comment: "다시 제출한 결론", outcome: :exception})
    broadcast_finding(ctx, ctx.finding.id)
    assert has_element?(view, "#conclusion-summary", "다시 제출한 결론")
    assert has_element?(view, "#conclusion-notice", "최신 결론을 확인한 뒤 결정하세요.")

    render_change(view, "validate", %{
      "conclusion" => %{"outcome" => "no_exception", "comment" => "우회 입력"}
    })

    assert has_element?(view, "#conclusion-summary", "다시 제출한 결론")
    refute has_element?(view, "#conclusion-form")
    assert Repo.aggregate(Conclusion, :count) == 2
  end

  test "can_decide remains false if the reviewer's own old conclusion is current", ctx do
    reviewer = user_fixture()
    member_fixture(ctx.scope, ctx.engagement, :reviewer, reviewer)
    insert_conclusion(ctx.finding, reviewer)
    set_finding(ctx.finding, status: :concluded)
    conn = log_in_user(build_conn(), reviewer)
    {:ok, view, _html} = open_finding(%{ctx | conn: conn})
    assert has_element?(view, "#sign-bar[data-can-decide=false]", "본인이 제출한 결론은 승인, 반려할 수 없습니다.")
    assert has_element?(view, "#finding-approve[disabled][aria-describedby=sign-bar-reason]")
  end

  test "unrelated finding messages do not reread the current finding", ctx do
    {:ok, view, _html} = open_finding(ctx)
    set_finding(ctx.finding, triage_status: :queued)
    broadcast_finding(ctx, Ecto.UUID.generate())
    assert has_element?(view, "#finding-ai-status", "미요청")
    refute has_element?(view, "#ai-triage-pending")
    broadcast_finding(ctx, ctx.finding.id)
    assert has_element?(view, "#ai-triage-pending", "분석 중")
  end

  test "every other engagement message is harmless to the S5 subscription", ctx do
    {:ok, view, _html} = open_finding(ctx)

    messages = [
      {:audit_appended,
       %{
         seq: 1,
         action: "test_run.completed",
         actor_type: :system,
         subject_type: "test_run",
         subject_id: ctx.run.id,
         entry_number: nil
       }},
      {:triage_requested, %{test_run_id: ctx.run.id, enqueued: 1}},
      {:test_run_updated, %{test_run_id: ctx.run.id, status: :completed, finding_count: 1}},
      {:import_updated,
       %{import_id: ctx.ledger_import.id, status: :succeeded, entry_count: 1, error_count: 0}},
      {:member_added, %{user_id: ctx.scope.user.id, role: :preparer}},
      {:rule_progress,
       %{
         test_run_id: ctx.run.id,
         rule_id: "round_amount",
         status: :succeeded,
         hit_count: 1,
         done: 3,
         total: 3
       }},
      {:run_completed, %{test_run_id: ctx.run.id, status: :completed, finding_count: 1}}
    ]

    Enum.each(messages, &Engagements.broadcast(ctx.engagement.id, &1))
    assert has_element?(view, "#finding-header h1", "JE-000123")
    assert has_element?(view, "#conclusion-form")
  end

  test "untrusted descriptions and counterparties appear as escaped original text", ctx do
    description = "<script>alert('desc')</script> 원문\n다음 줄"
    counterparty = "<img src=x onerror=alert('vendor')>"

    entry =
      insert_journal_entry(ctx.ledger_import, %{
        entry_number: "JE-ESCAPED",
        counterparty: counterparty
      })

    insert_line(entry, 1, "1310", "선급금", "1000000", "0", description)
    insert_line(entry, 2, "1020", "보통예금", "0", "1000000", description)
    finding = insert_finding(ctx.run, entry)
    {:ok, view, _html} = open_finding(%{ctx | finding: finding})
    assert has_element?(view, "#entry-description", "<script>alert('desc')</script> 원문")
    assert has_element?(view, "#entry-counterparty", counterparty)
    assert has_element?(view, "#entry-lines", "<script>alert('desc')</script>")
    refute has_element?(view, "#entry-description script")
    refute has_element?(view, "#entry-lines script")
    refute has_element?(view, "#entry-counterparty img")
  end

  defp open_finding(ctx),
    do: live(ctx.conn, ~p"/engagements/#{ctx.engagement}/findings/#{ctx.finding}")

  defp set_finding(finding, attrs), do: finding |> Ecto.Changeset.change(attrs) |> Repo.update!()

  defp insert_line(entry, number, code, name, debit, credit, description \\ "선급금 지급") do
    Repo.insert!(%JournalLine{
      journal_entry_id: entry.id,
      ledger_import_id: entry.ledger_import_id,
      line_number: number,
      account_code: code,
      account_name: name,
      debit: Decimal.new(debit),
      credit: Decimal.new(credit),
      description: description
    })
  end

  defp insert_hit(run, entry, rule_id, score, reason, details) do
    Repo.insert!(%RuleResult{
      test_run_id: run.id,
      journal_entry_id: entry.id,
      rule_id: rule_id,
      score: score,
      reason: reason,
      details: details
    })
  end

  defp insert_timed_triage(finding, at, attrs) do
    %AiTriage{finding_id: finding.id, inserted_at: at}
    |> AiTriage.changeset(valid_ai_triage_attrs(attrs))
    |> Repo.insert!()
  end

  defp insert_timed_conclusion(finding, preparer, at, attrs) do
    %Conclusion{finding_id: finding.id, preparer_id: preparer.id, inserted_at: at}
    |> Conclusion.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_decision(finding, conclusion, reviewer, decision, at, comment) do
    %ReviewDecision{
      finding_id: finding.id,
      conclusion_id: conclusion.id,
      preparer_id: conclusion.preparer_id,
      reviewer_id: reviewer.id,
      inserted_at: at
    }
    |> ReviewDecision.changeset(%{decision: decision, comment: comment})
    |> Repo.insert!()
  end

  defp reviewer_conn(ctx) do
    reviewer = user_fixture()
    member_fixture(ctx.scope, ctx.engagement, :reviewer, reviewer)
    log_in_user(build_conn(), reviewer)
  end

  defp broadcast_finding(ctx, id),
    do:
      Engagements.broadcast(
        ctx.engagement.id,
        {:finding_updated, %{finding_id: id, status: :concluded, triage_status: :succeeded}}
      )

  defp element_ids(view, selector),
    do:
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("id")
end
