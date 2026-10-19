defmodule TickmarkWeb.EngagementLiveTest do
  use TickmarkWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tickmark.AccountsFixtures
  import Tickmark.EngagementsFixtures
  import Tickmark.LedgerFixtures
  import Tickmark.SchemaFixtures

  alias Tickmark.Engagements
  alias Tickmark.Ledger
  alias Tickmark.Ledger.LedgerImport
  alias Tickmark.Repo
  alias Tickmark.Testing
  alias Tickmark.Testing.TestRunRule
  alias TickmarkWeb.EngagementLive.Components

  setup :register_and_log_in_user

  describe "Index (S1)" do
    test "lists only my engagements with my role", %{conn: conn, scope: scope} do
      mine =
        engagement_fixture(scope, %{
          client_name: "누리정밀 주식회사",
          performance_materiality: "225000000"
        })

      other_creator = user_scope_fixture()
      reviewing = engagement_fixture(other_creator, %{client_name: "한빛물산 주식회사"})
      member_fixture(other_creator, reviewing, :reviewer, scope.user)
      not_mine = engagement_fixture(other_creator, %{client_name: "다온유통 주식회사"})

      {:ok, view, html} = live(conn, ~p"/engagements")

      assert has_element?(view, "#engagements-#{mine.id}", "누리정밀 주식회사")
      assert has_element?(view, "#engagements-#{mine.id}", "FY2025")
      assert has_element?(view, "#engagements-#{mine.id}", "2025-12-31")
      assert has_element?(view, "#engagements-#{mine.id}", "225,000,000")
      assert has_element?(view, "#engagements-#{mine.id}", "작성자")

      assert has_element?(view, "#engagements-#{reviewing.id}", "한빛물산 주식회사")
      assert has_element?(view, "#engagements-#{reviewing.id}", "검토자")

      refute has_element?(view, "#engagements-#{not_mine.id}")
      refute html =~ "다온유통 주식회사"
    end

    test "shows the empty state when I have no engagements", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/engagements")

      assert has_element?(view, "#engagements-empty", "감사 대상이 없습니다.")
    end

    test "the new button opens the create panel and cancel closes it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/engagements")
      refute has_element?(view, "#engagement-form")

      view |> element("#new-engagement-button") |> render_click()
      assert_patch(view, ~p"/engagements/new")
      assert has_element?(view, "#engagement-form")

      view |> element("#engagement-form a", "취소") |> render_click()
      assert_patch(view, ~p"/engagements")
      refute has_element?(view, "#engagement-form")
    end

    test "shows validation errors while typing and on save", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/engagements/new")

      invalid = %{
        client_name: "",
        fiscal_year: "1999",
        period_end_date: "",
        performance_materiality: "0"
      }

      html = view |> form("#engagement-form", engagement: invalid) |> render_change()
      assert html =~ "can&#39;t be blank"
      assert html =~ "must be greater than or equal to 2000"
      assert html =~ "must be greater than 0"

      html = view |> form("#engagement-form", engagement: invalid) |> render_submit()
      assert html =~ "can&#39;t be blank"
      assert has_element?(view, "#engagement-form")
    end

    test "saving navigates to the new engagement", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/engagements/new")

      attrs = %{
        client_name: "누리정밀 주식회사",
        fiscal_year: "2025",
        period_end_date: "2025-12-31",
        performance_materiality: "225000000"
      }

      result = view |> form("#engagement-form", engagement: attrs) |> render_submit()

      assert [engagement] = Engagements.list_engagements(scope)
      {:ok, show_view, html} = follow_redirect(result, conn, ~p"/engagements/#{engagement}")

      assert html =~ "감사 대상을 만들었습니다."
      assert has_element?(show_view, "#engagement-overview", "225,000,000원")
      assert has_element?(show_view, "#members", scope.user.email)
    end

    test "shows the newest run status and its review queue", %{conn: conn, scope: scope} do
      completed = engagement_fixture(scope, %{client_name: "누리정밀 주식회사"})
      completed_import = insert_ledger_import(completed, scope.user)

      run =
        completed_import
        |> insert_test_run(scope.user, %{triage_threshold: 25})
        |> Ecto.Changeset.change(status: :completed)
        |> Repo.update!()

      for {number, score} <- [{"JE-001", 25}, {"JE-002", 60}, {"JE-003", 24}] do
        entry = insert_journal_entry(completed_import, %{entry_number: number})
        insert_finding(run, entry, %{score: score})
      end

      running = engagement_fixture(scope, %{client_name: "한빛소재 주식회사"})
      running |> insert_ledger_import(scope.user) |> insert_test_run(scope.user)
      no_run = engagement_fixture(scope, %{client_name: "세운물산 주식회사"})

      {:ok, view, _html} = live(conn, ~p"/engagements")

      assert has_element?(view, "#engagements-#{completed.id}-run", "완료")
      assert has_element?(view, "#engagements-#{completed.id}-queue", "2")
      assert has_element?(view, "#engagements-#{running.id}-run", "실행 중")
      assert has_element?(view, "#engagements-#{running.id}-queue", "없음")
      assert has_element?(view, "#engagements-#{no_run.id}-run", "없음")
      assert has_element?(view, "#engagements-#{no_run.id}-queue", "없음")
    end
  end

  describe "Show (S2)" do
    test "a preparer starts all rules for a loaded GL and navigates to S4", %{
      conn: conn,
      scope: scope
    } do
      engagement = engagement_fixture(scope)
      imported = ledger_import_fixture(scope, engagement, gl_csv(gl_entry("JE-001")))
      assert {:ok, %{status: :succeeded}} = Ledger.process_import(imported.id)

      {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}")
      assert has_element?(view, "#start-run-#{imported.id}", "테스트 실행")

      result = view |> element("#start-run-#{imported.id}") |> render_click()
      assert [run] = Testing.list_test_runs(scope, engagement.id)
      assert run.ledger_import_id == imported.id
      assert run.status == :running
      assert run.rule_count == length(Tickmark.Testing.Rules.ids())

      {:ok, run_view, _html} =
        follow_redirect(result, conn, ~p"/engagements/#{engagement}/runs/#{run}")

      assert has_element?(run_view, "#s4-running")
    end

    test "a start button opened before another run shows the run-in-progress flash", %{
      conn: conn,
      scope: scope
    } do
      engagement = engagement_fixture(scope)
      imported = succeeded_import(scope, engagement)
      {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}")
      assert has_element?(view, "#start-run-#{imported.id}")

      # Another request won the race, before this screen receives a state
      # message. The context's unique constraint still rejects this click.
      running = insert_test_run(imported, scope.user)
      view |> element("#start-run-#{imported.id}") |> render_click()

      assert has_element?(view, "#flash-error", "이 GL에 실행 중인 테스트가 있습니다.")
      assert [%{id: run_id}] = Testing.list_test_runs(scope, engagement.id)
      assert run_id == running.id
      refute_redirected(view)
    end

    test "there is no executable start button without any GL", %{conn: conn, scope: scope} do
      engagement = engagement_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}")

      assert has_element?(view, "#imports-empty")
      refute has_element?(view, "#imports button[phx-click='start_run']")
      assert Testing.list_test_runs(scope, engagement.id) == []
    end

    test "a failed GL has no start button and a forged event shows import-not-ready", %{
      conn: conn,
      scope: scope
    } do
      engagement = engagement_fixture(scope)
      [debit, credit] = gl_entry("JE-001")

      imported =
        ledger_import_fixture(scope, engagement, gl_csv([debit, %{credit | credit: "1"}]))

      assert {:ok, %{status: :failed}} = Ledger.process_import(imported.id)
      {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}")

      assert has_element?(view, "#imports-#{imported.id}", "실패")
      refute has_element?(view, "#imports button[phx-click='start_run']")

      render_hook(view, "start_run", %{"id" => imported.id})
      assert has_element?(view, "#flash-error", "적재가 끝난 GL만 테스트할 수 있습니다.")
      assert Testing.list_test_runs(scope, engagement.id) == []
    end

    test "a reviewer cannot start a loaded GL even with a forged event", %{
      conn: conn,
      scope: scope
    } do
      creator = user_scope_fixture()
      engagement = engagement_fixture(creator)
      member_fixture(creator, engagement, :reviewer, scope.user)
      imported = succeeded_import(creator, engagement)
      {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}")

      refute has_element?(view, "#start-run-#{imported.id}")
      render_hook(view, "start_run", %{"id" => imported.id})

      assert has_element?(view, "#flash-error", "테스트를 실행할 권한이 없습니다.")
      assert Testing.list_test_runs(creator, engagement.id) == []
    end

    test "the creator sees the overview, members, actions and empty sections", %{
      conn: conn,
      scope: scope
    } do
      engagement =
        engagement_fixture(scope, %{
          client_name: "누리정밀 주식회사",
          period_end_date: ~D[2025-12-31],
          performance_materiality: "225000000"
        })

      {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}")

      assert has_element?(view, "h1", "누리정밀 주식회사")
      assert has_element?(view, "#engagement-overview", "2025-12-31")
      assert has_element?(view, "#engagement-overview", "225,000,000원")

      assert has_element?(view, "#members", scope.user.email)
      assert has_element?(view, "#members", "작성자")
      assert has_element?(view, "#member-form")

      assert has_element?(
               view,
               "#import-link[href='#{~p"/engagements/#{engagement}/imports/new"}']",
               "GL 불러오기"
             )

      assert has_element?(view, "#audit-log-link[href='#{~p"/engagements/#{engagement}/audit"}']")

      assert has_element?(view, "#imports-empty", "아직 불러온 GL이 없습니다.")
      assert has_element?(view, "#test-runs-empty", "아직 테스트 실행이 없습니다.")
      assert has_element?(view, "#engagement-stats", "없음")
      assert has_element?(view, "#stats-section", "테스트를 실행하면 채워집니다")
    end

    test "lists GL imports and updates a row when its load finishes", %{conn: conn, scope: scope} do
      engagement = engagement_fixture(scope)
      csv = gl_csv(gl_entry("JE-0001", "1500000") ++ gl_entry("JE-0002", "2500000"))
      ledger_import = ledger_import_fixture(scope, engagement, csv)
      row = "#imports-#{ledger_import.id}"

      {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}")

      assert has_element?(view, row, "gl.csv")
      assert has_element?(view, row, "대기")
      assert has_element?(view, row, String.slice(ledger_import.sha256, 0, 8))

      # The worker's broadcasts reach the open screen without a reload.
      assert {:ok, %{status: :succeeded}} = Ledger.process_import(ledger_import.id)

      assert has_element?(view, row, "완료")
      assert has_element?(view, row, "4,000,000")
      refute has_element?(view, row, "대기")
    end

    test "a new import appears on top while the screen is open", %{conn: conn, scope: scope} do
      engagement = engagement_fixture(scope)
      older = ledger_import_fixture(scope, engagement, gl_csv(gl_entry("JE-0001")))

      {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}")
      newer = ledger_import_fixture(scope, engagement, gl_csv(gl_entry("JE-0002")))

      assert view |> element("#imports-#{newer.id}") |> has_element?()

      ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#imports tr[id^='imports-']:not(#imports-empty)")
        |> LazyHTML.attribute("id")

      assert ids == ["imports-#{newer.id}", "imports-#{older.id}"]
    end

    test "a non-member gets Ecto.NoResultsError", %{conn: conn} do
      engagement = engagement_fixture(user_scope_fixture())

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/engagements/#{engagement}")
      end
    end

    test "a malformed id gets Ecto.NoResultsError", %{conn: conn} do
      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/engagements/not-a-uuid")
      end
    end

    test "the creator adds a member and sees errors for unknown and existing emails", %{
      conn: conn,
      scope: scope
    } do
      engagement = engagement_fixture(scope)
      user = user_fixture()

      {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}")

      html =
        view
        |> form("#member-form", member: %{email: "nobody@example.com", role: "reviewer"})
        |> render_submit()

      assert html =~ "가입한 사용자 중 이 이메일이 없습니다."

      html =
        view
        |> form("#member-form", member: %{email: user.email, role: "reviewer"})
        |> render_submit()

      assert html =~ "멤버를 추가했습니다."
      assert [_creator, member] = Engagements.list_members(scope, engagement)
      assert has_element?(view, "#members-#{member.id}", user.email)
      assert has_element?(view, "#members-#{member.id}", "검토자")

      html =
        view
        |> form("#member-form", member: %{email: user.email, role: "preparer"})
        |> render_submit()

      assert html =~ "이미 이 감사 대상의 멤버입니다."
      assert length(Engagements.list_members(scope, engagement)) == 2
    end

    test "a reviewer sees the members and the audit log link but no member form or GL import", %{
      conn: conn,
      scope: scope
    } do
      creator = user_scope_fixture()
      engagement = engagement_fixture(creator)
      member_fixture(creator, engagement, :reviewer, scope.user)

      {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}")

      assert has_element?(view, "#members", creator.user.email)
      assert has_element?(view, "#members", scope.user.email)
      refute has_element?(view, "#member-form")
      refute has_element?(view, "#import-link")
      assert has_element?(view, "#audit-log-link")
    end

    test "a preparer who is not the creator gets the GL import link but no member form", %{
      conn: conn,
      scope: scope
    } do
      creator = user_scope_fixture()
      engagement = engagement_fixture(creator)
      member_fixture(creator, engagement, :preparer, scope.user)

      {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}")

      assert has_element?(view, "#import-link")
      refute has_element?(view, "#member-form")
    end

    test "a hand-crafted add_member event from a reviewer is refused", %{
      conn: conn,
      scope: scope
    } do
      creator = user_scope_fixture()
      engagement = engagement_fixture(creator)
      member_fixture(creator, engagement, :reviewer, scope.user)
      outsider = user_fixture()

      {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}")

      html =
        render_hook(view, "add_member", %{
          "member" => %{"email" => outsider.email, "role" => "reviewer"}
        })

      assert html =~ "멤버를 추가할 권한이 없습니다."
      assert length(Engagements.list_members(creator, engagement)) == 2
    end

    test "lists runs newest first with stats from the newest finished run", %{
      conn: conn,
      scope: scope
    } do
      engagement = engagement_fixture(scope)
      busy = succeeded_import(scope, engagement)
      idle = succeeded_import(scope, engagement)
      pending = insert_ledger_import(engagement, scope.user)

      done = finished_run(busy, scope, %{rule_count: 2, finding_count: 3})
      insert_rule(done, "round_amount", :succeeded)
      insert_rule(done, "duplicate_entry", :failed)
      insert_finding(done, insert_journal_entry(busy), %{score: 30, status: :approved})
      insert_finding(done, insert_journal_entry(busy), %{score: 60})
      insert_finding(done, insert_journal_entry(busy), %{score: 10})

      running =
        insert_test_run(busy, scope.user, %{started_at: DateTime.add(done.started_at, 60)})

      {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}")

      assert has_element?(view, "#engagement-stats", "12")
      assert has_element?(view, "#engagement-stats", "30")
      assert has_element?(view, "#engagement-stats", "점수 25 이상")
      assert has_element?(view, "#engagement-stats", "/ 2")
      refute has_element?(view, "#stats-section", "테스트를 실행하면 채워집니다")

      assert run_row_ids(view) == ["test-runs-#{running.id}", "test-runs-#{done.id}"]
      assert has_element?(view, "#test-runs-#{running.id}", "실행 중")
      assert has_element?(view, "#test-runs-#{running.id}", "없음")
      assert has_element?(view, "#test-runs-#{done.id}", "일부 실패")
      assert has_element?(view, "#test-runs-#{done.id}", "2 / 2")

      assert has_element?(
               view,
               "#test-runs-#{done.id} a[href='#{~p"/engagements/#{engagement}/runs/#{done}"}']",
               "열기"
             )

      # One running run per import: the start button waits on that import only.
      assert has_element?(view, "#imports-#{busy.id}", "이 GL에 실행 중인 테스트가 있습니다.")
      refute has_element?(view, "#start-run-#{busy.id}")
      assert has_element?(view, "#start-run-#{idle.id}", "테스트 실행")
      refute has_element?(view, "#start-run-#{pending.id}")
    end

    test "test_run_updated redraws the run row, the stats and the start button", %{
      conn: conn,
      scope: scope
    } do
      engagement = engagement_fixture(scope)
      ledger_import = succeeded_import(scope, engagement)
      run = insert_test_run(ledger_import, scope.user)

      {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}")
      refute has_element?(view, "#start-run-#{ledger_import.id}")

      run
      |> Ecto.Changeset.change(status: :completed, finding_count: 1)
      |> Repo.update!()

      insert_finding(run, insert_journal_entry(ledger_import), %{score: 40})

      :ok =
        Engagements.broadcast(
          engagement.id,
          {:test_run_updated, %{test_run_id: run.id, status: :completed, finding_count: 1}}
        )

      assert has_element?(view, "#test-runs-#{run.id}", "완료")
      assert has_element?(view, "#engagement-stats", "점수 25 이상")
      assert has_element?(view, "#start-run-#{ledger_import.id}")
    end

    test "a reviewer gets no start button", %{conn: conn, scope: scope} do
      creator = user_scope_fixture()
      engagement = engagement_fixture(creator)
      member_fixture(creator, engagement, :reviewer, scope.user)
      ledger_import = succeeded_import(creator, engagement)

      {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}")

      assert has_element?(view, "#imports-#{ledger_import.id}", "완료")
      refute has_element?(view, "#start-run-#{ledger_import.id}")
      refute has_element?(view, "#imports-section th", "행동")
    end

    # :import_updated and :test_run_updated are covered by the tests above.
    test "the other topic messages keep the screen running", %{conn: conn, scope: scope} do
      engagement = engagement_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}")

      id = Ecto.UUID.generate()

      :ok =
        Engagements.broadcast(
          engagement.id,
          {:finding_updated, %{finding_id: id, status: :open, triage_status: :pending}}
        )

      :ok =
        Engagements.broadcast(
          engagement.id,
          {:audit_appended, %{seq: 1, action: "engagement.created"}}
        )

      :ok =
        Engagements.broadcast(
          engagement.id,
          {:triage_requested, %{test_run_id: Ecto.UUID.generate(), enqueued: 3}}
        )

      assert render(view) =~ engagement.client_name
      assert Process.alive?(view.pid)
    end
  end

  describe "Components" do
    test "import_source/1 names the upload or the generator seed" do
      assert Components.import_source(%LedgerImport{
               source_kind: :upload,
               original_filename: "gl-2025.csv"
             }) == "gl-2025.csv"

      assert Components.import_source(%LedgerImport{
               source_kind: :generated,
               original_filename: "synthetic-gl-seed-20251231.csv"
             }) == "합성 GL, 시드 20251231"
    end

    test "format_kst/1 shows UTC as KST, across the date line" do
      assert Components.format_kst(~U[2025-12-31 15:42:10Z]) == "2026-01-01 00:42"
      assert Components.format_count(19_804) == "19,804"
    end
  end

  defp succeeded_import(scope, engagement) do
    engagement
    |> insert_ledger_import(scope.user)
    |> Ecto.Changeset.change(status: :succeeded, entry_count: 12, line_count: 30)
    |> Repo.update!()
  end

  defp finished_run(ledger_import, scope, attrs) do
    ledger_import
    |> insert_test_run(scope.user, Map.take(attrs, [:rule_count]))
    |> Ecto.Changeset.change(status: :completed_with_errors, finding_count: attrs.finding_count)
    |> Repo.update!()
  end

  defp insert_rule(run, rule_id, status) do
    %TestRunRule{test_run_id: run.id}
    |> TestRunRule.create_changeset(%{rule_id: rule_id})
    |> Repo.insert!()
    |> Ecto.Changeset.change(status: status)
    |> Repo.update!()
  end

  defp run_row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#test-runs tr[id^='test-runs-']:not(#test-runs-empty)")
    |> LazyHTML.attribute("id")
  end
end
