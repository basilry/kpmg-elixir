defmodule TickmarkWeb.FindingLive.TriageActionsTest do
  use TickmarkWeb.ConnCase, async: true
  use Oban.Testing, repo: Tickmark.Repo

  import Phoenix.LiveViewTest
  import Tickmark.EngagementsFixtures
  import Tickmark.SchemaFixtures

  alias Tickmark.Repo
  alias Tickmark.AuditTrail.AuditEvent
  alias Tickmark.Testing.Finding
  alias Tickmark.Triage.TriageWorker

  setup :register_and_log_in_user

  setup %{scope: scope} do
    engagement = engagement_fixture(scope)
    ledger_import = insert_ledger_import(engagement, scope.user)
    run = insert_test_run(ledger_import, scope.user)
    run |> Ecto.Changeset.change(status: :completed) |> Repo.update!()
    finding = insert_finding(run, insert_journal_entry(ledger_import))

    %{
      engagement: engagement,
      run: run,
      finding: finding,
      path: ~p"/engagements/#{engagement}/findings/#{finding}"
    }
  end

  test "a preparer request queues the finding, logs the requester and shows progress", ctx do
    {:ok, view, _html} = live(ctx.conn, ctx.path)
    assert has_element?(view, "#ai-triage-request:not([disabled])", "AI 제안 요청")

    view |> element("#ai-triage-request") |> render_click()

    assert Repo.get!(Finding, ctx.finding.id).triage_status == :queued
    assert_enqueued worker: TriageWorker, queue: :llm, args: %{finding_id: ctx.finding.id}

    event = Repo.get_by!(AuditEvent, action: "ai_triage.requested", subject_id: ctx.finding.id)
    assert event.actor_id == ctx.scope.user.id

    assert has_element?(view, "#flash-info", "AI 제안을 요청했습니다")
    assert has_element?(view, "#ai-triage-card[aria-busy=true]", "분석 중")
    refute has_element?(view, "#ai-triage-request")
  end

  test "a failed suggestion can be requested again", ctx do
    ctx.finding |> Ecto.Changeset.change(triage_status: :failed) |> Repo.update!()
    {:ok, view, _html} = live(ctx.conn, ctx.path)

    view |> element("#ai-triage-request:not([disabled])", "다시 요청") |> render_click()

    assert Repo.get!(Finding, ctx.finding.id).triage_status == :queued
    assert has_element?(view, "#ai-triage-pending")
  end

  test "a click on a stale button for an already queued finding only reports it", ctx do
    {:ok, view, _html} = live(ctx.conn, ctx.path)
    ctx.finding |> Ecto.Changeset.change(triage_status: :queued) |> Repo.update!()

    view |> element("#ai-triage-request") |> render_click()

    assert has_element?(view, "#flash-info", "이미 분석 중입니다.")
    assert has_element?(view, "#ai-triage-pending")
    refute_enqueued worker: TriageWorker
  end

  test "a reviewer sees the button disabled and a forged click changes nothing", ctx do
    reviewer = member_scope_fixture(ctx.scope, ctx.engagement, :reviewer)
    conn = log_in_user(build_conn(), reviewer.user)
    {:ok, view, _html} = live(conn, ctx.path)

    assert has_element?(view, "#ai-triage-request[disabled]", "AI 제안 요청")
    assert has_element?(view, "#ai-triage-request-help", "작성자만 요청할 수 있습니다.")

    render_click(view, "request_triage", %{})

    assert has_element?(view, "#flash-error", "AI 제안을 요청할 권한이 없습니다.")
    assert Repo.get!(Finding, ctx.finding.id).triage_status == :none
    refute_enqueued worker: TriageWorker
  end
end
