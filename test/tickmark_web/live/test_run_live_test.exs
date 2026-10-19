defmodule TickmarkWeb.TestRunLiveTest do
  use TickmarkWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tickmark.AccountsFixtures
  import Tickmark.EngagementsFixtures
  import Tickmark.SchemaFixtures

  alias Tickmark.{Engagements, Repo, Testing}
  alias Tickmark.Testing.TestRunRule

  setup :register_and_log_in_user

  setup %{scope: scope} do
    engagement = engagement_fixture(scope)

    ledger_import =
      insert_ledger_import(engagement, scope.user, %{
        original_filename: "synthetic-gl-seed-20251231.csv"
      })

    run =
      insert_test_run(ledger_import, scope.user, %{
        rule_count: 3,
        triage_threshold: 40,
        started_at: ~U[2026-10-19 01:02:04Z]
      })

    %{engagement: engagement, ledger_import: ledger_import, run: run}
  end

  test "shows rule status and hit counts in context order while the findings queue waits", ctx do
    %{conn: conn, engagement: engagement, run: run} = ctx
    insert_rule(run, "test_skip", status: :skipped, error: "모집단 500건 미만")
    insert_rule(run, "test_error", status: :queued)
    insert_rule(run, "approval_control_gap", status: :running)
    {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}/runs/#{run}")

    assert has_element?(view, "#s4-main-1 h1", "2026-10-19 10:02")
    assert has_element?(view, "#s4-main-1", "합성 GL, 시드 20251231")
    assert has_element?(view, "#s4-main-1", "기준 점수 40")
    assert has_element?(view, "#s4-progress-summary", "실행 중")
    assert has_element?(view, "#s4-progress-summary", "1 / 3 룰")
    assert has_element?(view, "#s4-progress[value='1'][max='3']")
    assert has_element?(view, "#s4-rule-approval_control_gap", "승인 통제 이탈")
    assert has_element?(view, "#s4-rule-approval_control_gap", "집계 중")
    assert has_element?(view, "#s4-rule-test_error", "대기")
    assert has_element?(view, "#s4-rule-test_skip", "미실행")
    assert has_element?(view, "#s4-rule-test_skip", "모집단 500건 미만")
    assert has_element?(view, "#s4-running", "룰이 모두 끝나면 검토 큐가 열립니다.")
    refute has_element?(view, "#s4-findings")

    expected =
      Testing.get_test_run!(ctx.scope, run.id).test_run_rules
      |> Enum.map(&"s4-rule-#{&1.rule_id}")

    assert element_ids(view, "#s4-rules > li") == expected
  end

  test "rule_progress and run_completed broadcasts reread progress and open findings", ctx do
    %{conn: conn, engagement: engagement, ledger_import: ledger_import, run: run} = ctx
    rule = insert_rule(run, "approval_control_gap", status: :running)
    insert_rule(run, "test_skip", status: :skipped, error: "모집단 500건 미만")
    insert_rule(run, "test_error", status: :succeeded, hit_count: 0)
    {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}/runs/#{run}")
    rule |> Ecto.Changeset.change(status: :succeeded, hit_count: 7) |> Repo.update!()

    broadcast_run(
      run,
      {:rule_progress,
       %{
         test_run_id: run.id,
         rule_id: rule.rule_id,
         status: :succeeded,
         hit_count: 7,
         done: 3,
         total: 3
       }}
    )

    assert has_element?(view, "#s4-rule-approval_control_gap", "7건")
    assert has_element?(view, "#s4-progress[value='3']")

    entry = insert_journal_entry(ledger_import, %{entry_number: "JE-000001"})
    finding = insert_finding(run, entry, %{score: 40, rule_ids: ["approval_control_gap"]})
    run = complete_run(run, finding_count: 1)

    broadcast_run(
      run,
      {:run_completed, %{test_run_id: run.id, status: :completed, finding_count: 1}}
    )

    assert has_element?(view, "#s4-progress-summary", "완료")
    assert has_element?(view, "#s4-progress-summary", "적중 전표 1건")
    assert has_element?(view, "#s4-finding-#{finding.id}", "JE-000001")
    assert has_element?(view, "#s4-tab-queue .badge", "1")
    refute has_element?(view, "#s4-running")
  end

  test "queue, minor and all tabs use the run threshold and preserve score order", ctx do
    %{conn: conn, engagement: engagement, ledger_import: ledger_import, run: run} = ctx
    findings = insert_findings(run, ledger_import)
    run = complete_run(run, finding_count: 4)
    {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}/runs/#{run}")

    assert has_element?(view, "#s4-tab-queue[aria-current=page] .badge", "2")
    assert has_element?(view, "#s4-tab-minor .badge", "2")
    assert has_element?(view, "#s4-tab-all .badge", "4")

    assert finding_ids(view) ==
             Enum.map([findings.high, findings.boundary], &"s4-finding-#{&1.id}")

    assert has_element?(view, "#s4-finding-#{findings.high.id} td.text-right", "1,250,000")
    assert has_element?(view, "#s4-finding-#{findings.high.id}", "2025-03-31")

    assert has_element?(
             view,
             "#s4-finding-#{findings.high.id} a[href='/engagements/#{engagement.id}/findings/#{findings.high.id}']",
             "JE-000001"
           )

    view |> element("#s4-tab-minor") |> render_click()
    assert_patch(view, ~p"/engagements/#{engagement}/runs/#{run}?tab=minor")
    assert finding_ids(view) == Enum.map([findings.minor, findings.low], &"s4-finding-#{&1.id}")
    refute has_element?(view, "#s4-main-7")
    refute has_element?(view, "#s4-main-3")

    view |> element("#s4-tab-all") |> render_click()
    assert length(finding_ids(view)) == 4
    assert has_element?(view, "#s4-main-7", "AI 위험도")
  end

  test "rule and review status filters reset the stream and handle no matches", ctx do
    %{conn: conn, engagement: engagement, ledger_import: ledger_import, run: run} = ctx
    insert_rule(run, "approval_control_gap", status: :succeeded, hit_count: 2)
    insert_rule(run, "round_amount", status: :succeeded, hit_count: 2)
    insert_rule(run, "period_end_manual", status: :succeeded, hit_count: 1)
    findings = insert_findings(run, ledger_import)
    run = complete_run(run, finding_count: 4)
    {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}/runs/#{run}?tab=all")

    view
    |> form("#s4-main-5", filter: %{rule_id: "approval_control_gap", status: ""})
    |> render_change()

    assert finding_ids(view) ==
             Enum.map([findings.high, findings.boundary], &"s4-finding-#{&1.id}")

    assert has_element?(view, "#s4-rule-filter option[value=approval_control_gap][selected]")

    view
    |> form("#s4-main-5", filter: %{rule_id: "approval_control_gap", status: "concluded"})
    |> render_change()

    assert finding_ids(view) == ["s4-finding-#{findings.boundary.id}"]
    assert has_element?(view, "#s4-finding-#{findings.boundary.id} [data-column=review]", "검토 대기")

    view
    |> form("#s4-main-5", filter: %{rule_id: "approval_control_gap", status: "rejected"})
    |> render_change()

    assert finding_ids(view) == []
    assert has_element?(view, "#s4-findings-empty", "조건에 맞는 전표가 없습니다.")
    assert has_element?(view, "#s4-tab-all .badge", "4")
  end

  test "failed rule errors never appear in HTML while skipped reasons remain visible", ctx do
    %{conn: conn, engagement: engagement, run: run} = ctx
    insert_rule(run, "approval_control_gap", status: :succeeded, hit_count: 3)

    insert_rule(run, "test_error",
      status: :failed,
      error: "PRIVATE-SQL-ERROR <script>internal()</script>"
    )

    insert_rule(run, "test_skip", status: :skipped, error: "모집단 500건 미만")
    run = complete_run(run, status: :completed_with_errors)
    {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}/runs/#{run}")

    assert has_element?(view, "#s4-progress-summary", "일부 실패")
    assert has_element?(view, "#s4-progress[value='3'][max='3']")
    assert has_element?(view, "#s4-rule-test_error", "실행 실패, 로그 확인")
    assert has_element?(view, "#s4-rule-test_skip", "모집단 500건 미만")
    assert has_element?(view, "#s4-rule-failure", "룰 1개를 실행하지 못했습니다.")
    refute render(view) =~ "PRIVATE-SQL-ERROR"
    refute render(view) =~ "internal()"
  end

  test "AI and preparer judgement stay as dash placeholders with no active request", ctx do
    %{conn: conn, engagement: engagement, ledger_import: ledger_import, run: run} = ctx
    findings = insert_findings(run, ledger_import)
    run = complete_run(run, finding_count: 4)
    {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}/runs/#{run}")
    assert has_element?(view, "#s4-triage-summary", "-")
    assert has_element?(view, "#s4-triage-request[disabled][aria-label='AI 트리아지 요청']", "-")
    assert has_element?(view, "#s4-finding-#{findings.high.id} [data-column=ai]", "-")
    assert has_element?(view, "#s4-finding-#{findings.high.id} [data-column=conclusion]", "-")
  end

  test "finding_updated refreshes filters and counts and unrelated run messages are ignored",
       ctx do
    %{conn: conn, engagement: engagement, ledger_import: ledger_import, run: run} = ctx
    findings = insert_findings(run, ledger_import)
    run = complete_run(run, finding_count: 4)
    {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}/runs/#{run}?status=open")
    assert finding_ids(view) == ["s4-finding-#{findings.high.id}"]
    findings.high |> Ecto.Changeset.change(status: :concluded) |> Repo.update!()

    Phoenix.PubSub.broadcast(
      Tickmark.PubSub,
      Engagements.topic(engagement.id),
      {:finding_updated,
       %{finding_id: findings.high.id, status: :concluded, triage_status: :none}}
    )

    assert finding_ids(view) == []

    broadcast_run(
      run,
      {:rule_progress,
       %{
         test_run_id: Ecto.UUID.generate(),
         rule_id: "test_error",
         status: :failed,
         hit_count: 0,
         done: 1,
         total: 1
       }}
    )

    broadcast_run(
      run,
      {:run_completed,
       %{test_run_id: Ecto.UUID.generate(), status: :completed_with_errors, finding_count: 999}}
    )

    assert has_element?(view, "#s4-progress-summary", "적중 전표 4건")
  end

  test "an engagement id cannot be used with another engagement's visible run", ctx do
    %{conn: conn, scope: scope, engagement: engagement, run: run} = ctx
    other = engagement_fixture(scope)
    assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/engagements/#{other}/runs/#{run}") end
    hidden_engagement = engagement_fixture(user_scope_fixture())

    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/engagements/#{hidden_engagement}/runs/#{run}")
    end

    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/engagements/#{engagement}/runs/not-a-uuid")
    end
  end

  test "a reviewer can read the same findings", %{conn: conn, scope: scope} do
    creator = user_scope_fixture()
    engagement = engagement_fixture(creator)
    member_fixture(creator, engagement, :reviewer, scope.user)
    ledger_import = insert_ledger_import(engagement, creator.user)
    run = insert_test_run(ledger_import, creator.user) |> complete_run(finding_count: 1)
    entry = insert_journal_entry(ledger_import, %{entry_number: "JE-REVIEW"})
    finding = insert_finding(run, entry)
    {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}/runs/#{run}")
    assert has_element?(view, "#s4-finding-#{finding.id}", "JE-REVIEW")
    assert has_element?(view, "#s4-triage-request[disabled]")
  end

  defp insert_rule(run, id, attrs) do
    TestRunRule
    |> struct!(Keyword.merge([test_run_id: run.id, rule_id: id], attrs))
    |> Repo.insert!()
  end

  defp complete_run(run, attrs) do
    run
    |> Ecto.Changeset.change(
      Keyword.merge([status: :completed, finished_at: ~U[2026-10-19 01:02:19.000000Z]], attrs)
    )
    |> Repo.update!()
  end

  defp insert_findings(run, ledger_import) do
    specs = [
      {:high, "JE-000001", 60, ["approval_control_gap", "round_amount"], :open},
      {:boundary, "JE-000002", 40, ["approval_control_gap", "period_end_manual"], :concluded},
      {:minor, "JE-000003", 39, ["round_amount"], :approved},
      {:low, "JE-000004", 10, ["round_amount"], :rejected}
    ]

    Map.new(specs, fn {key, number, score, rule_ids, status} ->
      entry =
        insert_journal_entry(ledger_import, %{
          entry_number: number,
          total_debit: Decimal.new("1250000"),
          total_credit: Decimal.new("1250000")
        })

      {key,
       insert_finding(run, entry, %{
         score: score,
         rule_ids: Enum.sort(rule_ids),
         hit_count: length(rule_ids),
         status: status
       })}
    end)
  end

  defp broadcast_run(run, message),
    do: Phoenix.PubSub.broadcast(Tickmark.PubSub, Testing.run_topic(run.id), message)

  defp element_ids(view, selector),
    do:
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("id")

  defp finding_ids(view), do: element_ids(view, "#s4-findings > tr:not(#s4-findings-empty)")
end
