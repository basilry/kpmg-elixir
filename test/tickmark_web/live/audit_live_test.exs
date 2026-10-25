defmodule TickmarkWeb.AuditLiveTest do
  use TickmarkWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tickmark.AccountsFixtures
  import Tickmark.SchemaFixtures

  alias Tickmark.{AuditTrail, Engagements, Repo}
  alias Tickmark.AuditTrail.AuditEvent

  setup :register_and_log_in_user

  setup %{scope: scope} do
    engagement = insert_engagement(scope.user)
    insert_member(engagement, scope.user, :preparer)
    %{engagement: engagement}
  end

  test "non-members, missing engagements and malformed ids all receive 404", ctx do
    hidden = insert_engagement(user_fixture())

    for id <- [hidden.id, Ecto.UUID.generate(), "not-a-uuid"] do
      assert_raise Ecto.NoResultsError, fn ->
        live(ctx.conn, ~p"/engagements/#{id}/audit")
      end
    end
  end

  test "shows the three actors, Korean actions, KST times, subject links and original JSON",
       ctx do
    person =
      insert_event(ctx,
        action: "conclusion.submitted",
        subject_type: "finding",
        subject_id: Ecto.UUID.generate(),
        payload: %{"entry_number" => "JE-000123", "outcome" => "exception"}
      )

    agent =
      insert_event(ctx,
        actor: {:agent, "triage:fake-triage-v1"},
        action: "ai_triage.completed",
        subject_type: "finding",
        subject_id: Ecto.UUID.generate(),
        payload: %{"entry_number" => "JE-000123", "risk_level" => "medium", "reused" => true}
      )

    system =
      insert_event(ctx,
        actor: {:system, "ledger.import_worker"},
        action: "ledger_import.succeeded",
        subject_type: "ledger_import",
        subject_id: Ecto.UUID.generate(),
        payload: %{
          "entry_count" => 8341,
          "line_count" => 19804,
          "total_debit" => "386214905000",
          "warning_count" => 0,
          "snapshot" => %{"raw" => [nil, false, "<script>unsafe()</script>"]}
        }
      )

    {:ok, view, _html} = live(ctx.conn, ~p"/engagements/#{ctx.engagement}/audit")

    assert has_element?(view, "#s6 h1", "감사 로그")
    assert has_element?(view, "#s6", "읽기 전용. 기록은 수정하거나 삭제할 수 없습니다.")
    assert event_ids(view) == Enum.map([system, agent, person], &"audit-event-#{&1.seq}")
    assert has_element?(view, row(person) <> " [data-column=actor]", ctx.user.email)
    assert has_element?(view, row(agent) <> " [data-column=actor]", "triage:fake-triage-v1")
    assert has_element?(view, row(system) <> " [data-column=actor]", "ledger.import_worker")
    assert has_element?(view, row(person) <> " .hero-user-circle")
    assert has_element?(view, row(agent) <> " .hero-sparkles")
    assert has_element?(view, row(system) <> " .hero-cog-6-tooth")

    assert has_element?(
             view,
             row(person) <>
               " time[datetime='2026-10-19T01:02:03.000000Z'][title='2026-10-19 01:02:03 UTC']",
             "2026-10-19 10:02:03"
           )

    assert has_element?(view, row(person) <> " [data-column=action]", "결론 제출")
    assert has_element?(view, row(person) <> " code", "conclusion.submitted")
    assert has_element?(view, row(person) <> " [data-column=summary]", "예외")
    assert has_element?(view, row(agent) <> " [data-column=summary]", "위험도 중간 (기존 제안 재사용)")
    assert has_element?(view, row(system) <> " [data-column=summary]", "전표 8,341건, 라인 19,804건")

    assert has_element?(
             view,
             row(person) <>
               " a[href='/engagements/#{ctx.engagement.id}/findings/#{person.subject_id}']",
             "JE-000123"
           )

    assert has_element?(
             view,
             row(system) <>
               " a[href='/engagements/#{ctx.engagement.id}#imports-#{system.subject_id}']"
           )

    assert has_element?(view, row(system) <> " details summary", "payload")
    refute has_element?(view, row(system) <> " details[open]")
    assert payload_json(view, system) == system.payload
    refute has_element?(view, row(system) <> " details script")
    refute has_element?(view, "#s6 [phx-click=delete], #s6 [phx-click=edit]")
  end

  test "uses contract payload snapshots for action summaries without reading the subjects", ctx do
    specs = [
      {"engagement.created", "engagement", %{"fiscal_year" => 2025}, "감사 대상 생성", "FY2025"},
      {"engagement.member_added", "engagement", %{"role" => "reviewer"}, "멤버 추가", "검토자 추가"},
      {"ledger_import.created", "ledger_import",
       %{"source_kind" => "generated", "original_filename" => "seed.csv"}, "GL 적재 시작", "합성 GL"},
      {"ledger_import.failed", "ledger_import",
       %{"reason" => "validation_failed", "error_count" => 4}, "GL 적재 실패", "입력 검증 실패, 오류 4건"},
      {"test_run.started", "test_run",
       %{"rule_ids" => ["round_amount", "off_hours_entry"], "triage_threshold" => 25},
       "테스트 실행 시작", "룰 2개, 기준 점수 25"},
      {"test_run_rule.failed", "test_run", %{"rule_id" => "approval_control_gap"}, "룰 실행 실패",
       "승인 통제 이탈"},
      {"test_run.completed", "test_run",
       %{"status" => "completed_with_errors", "finding_count" => 265}, "테스트 실행 완료",
       "일부 실패, 적중 전표 265건"},
      {"ai_triage.requested", "test_run", %{"enqueued" => 52}, "AI 제안 요청", "52건 요청"},
      {"ai_triage.failed", "finding", %{"reason" => "worker_crashed"}, "AI 제안 실패", "작업 실행 실패"},
      {"conclusion.submitted", "finding", %{"outcome" => "no_exception"}, "결론 제출", "이상 없음"},
      {"conclusion.submitted", "finding", %{"outcome" => "needs_follow_up"}, "결론 제출", "추가 확인 필요"},
      {"review.rejected", "finding", %{"comment" => "급여대장과 대사해 주세요.\n재제출 때 첨부해 주세요."}, "반려",
       "급여대장과 대사해 주세요."},
      {"review.approved", "finding", %{}, "승인", nil},
      {"review.denied", "finding", %{"reason" => "self_review", "attempted" => "approved"},
       "검토 거부됨", "본인이 제출한 결론은 승인, 반려할 수 없습니다"}
    ]

    events =
      Enum.map(specs, fn {action, type, payload, label, summary} ->
        payload =
          if type == "finding", do: Map.put(payload, "entry_number", "JE-000777"), else: payload

        event =
          insert_event(ctx,
            action: action,
            subject_type: type,
            subject_id: Ecto.UUID.generate(),
            payload: payload
          )

        {event, label, summary}
      end)

    {:ok, view, _html} = live(ctx.conn, ~p"/engagements/#{ctx.engagement}/audit")

    for {event, label, summary} <- events do
      assert has_element?(view, row(event) <> " [data-column=action]", label)
      assert payload_json(view, event) == event.payload
      if summary, do: assert(has_element?(view, row(event) <> " [data-column=summary]", summary))

      if event.subject_type == "test_run" do
        assert has_element?(
                 view,
                 row(event) <>
                   " a[href='/engagements/#{ctx.engagement.id}/runs/#{event.subject_id}']"
               )
      end

      if event.subject_type == "engagement" do
        assert has_element?(view, row(event) <> " a[href='/engagements/#{ctx.engagement.id}']")
      end
    end

    {denied, _, _} = List.last(events)
    assert has_element?(view, row(denied) <> ".border-l-warning .hero-exclamation-triangle")
  end

  test "actor and entry-number patches reset the stream, compose, and keep one pressed button",
       ctx do
    person = insert_event(ctx)
    agent = insert_finding_event(ctx, "JE-000123", actor: {:agent, "triage:fake-triage-v1"})
    other = insert_finding_event(ctx, "JE-000999", actor: {:agent, "triage:fake-triage-v1"})
    {:ok, view, _html} = live(ctx.conn, ~p"/engagements/#{ctx.engagement}/audit")

    view |> element("#actor-filter-agent") |> render_click()
    assert_patch(view, ~p"/engagements/#{ctx.engagement}/audit?actor=agent")
    assert event_ids(view) == Enum.map([other, agent], &"audit-event-#{&1.seq}")
    assert selected_actor(view) == ["actor-filter-agent"]
    refute has_element?(view, row(person))

    view |> form("#subject-filter-form", filter: %{subject: "JE-000123"}) |> render_submit()
    assert_patch(view, ~p"/engagements/#{ctx.engagement}/audit?actor=agent&subject=JE-000123")
    assert event_ids(view) == ["audit-event-#{agent.seq}"]
    assert has_element?(view, "#subject-filter[value=JE-000123]")

    view |> element("#actor-filter-user") |> render_click()
    assert_patch(view, ~p"/engagements/#{ctx.engagement}/audit?actor=user&subject=JE-000123")
    assert event_ids(view) == []
    assert has_element?(view, "#audit-events-empty", "조건에 맞는 이벤트가 없습니다.")

    view |> element("#reset-filters") |> render_click()
    assert_patch(view, ~p"/engagements/#{ctx.engagement}/audit")
    assert event_ids(view) == Enum.map([other, agent, person], &"audit-event-#{&1.seq}")
    assert selected_actor(view) == ["actor-filter-all"]
  end

  test "invalid URL filter values are ignored", ctx do
    event = insert_event(ctx)

    for query <- [
          %{actor: "administrator", subject: "   ", run: "not-a-uuid"},
          %{actor: ["agent"], subject: ["JE-000123"], run: [Ecto.UUID.generate()]},
          %{subject: String.duplicate("a", 201)},
          %{subject: "JE-000123\n"},
          %{subject: "JE-000123\u0000"}
        ] do
      {:ok, view, _html} = live(ctx.conn, ~p"/engagements/#{ctx.engagement}/audit?#{query}")
      assert event_ids(view) == ["audit-event-#{event.seq}"]
      assert selected_actor(view) == ["actor-filter-all"]
      assert has_element?(view, "#subject-filter[value='']")
      refute has_element?(view, "#clear-run-filter")
    end
  end

  test "entry-number filters preserve leading zeros, spaces and literal punctuation", ctx do
    exact = insert_finding_event(ctx, " 000123 ' ")
    insert_finding_event(ctx, "123")

    {:ok, view, _html} =
      live(ctx.conn, ~p"/engagements/#{ctx.engagement}/audit?subject=#{" 000123 ' "}")

    assert event_ids(view) == ["audit-event-#{exact.seq}"]
  end

  test "new events are counted once, stay out of the list, and refresh focuses the first row",
       ctx do
    first = insert_event(ctx)
    {:ok, view, _html} = live(ctx.conn, ~p"/engagements/#{ctx.engagement}/audit")
    refute has_element?(view, "#new-events")
    new = insert_event(ctx)
    :ok = AuditTrail.broadcast_appended(new)
    assert has_element?(view, "#new-events", "새 이벤트 1건")
    assert event_ids(view) == ["audit-event-#{first.seq}"]

    :ok = AuditTrail.broadcast_appended(new)
    :ok = AuditTrail.broadcast_appended(first)
    assert has_element?(view, "#new-events", "새 이벤트 1건")

    view |> element("#new-events") |> render_click()
    assert event_ids(view) == Enum.map([new, first], &"audit-event-#{&1.seq}")
    refute has_element?(view, "#new-events")
    assert has_element?(view, row(new) <> "[tabindex='-1']")
    first_id = "audit-event-#{new.seq}"
    assert_push_event(view, "audit:focus-first", %{id: ^first_id})
  end

  test "new-event counts honor actor and entry-number filters, including an initially empty list",
       ctx do
    insert_finding_event(ctx, "JE-OTHER")

    {:ok, view, _html} =
      live(ctx.conn, ~p"/engagements/#{ctx.engagement}/audit?actor=agent&subject=JE-000123")

    assert event_ids(view) == []

    wrong_actor = insert_finding_event(ctx, "JE-000123")
    wrong_entry = insert_finding_event(ctx, "JE-OTHER", actor: {:agent, "triage:fake-triage-v1"})

    for event <- [wrong_actor, wrong_entry], do: :ok = AuditTrail.broadcast_appended(event)
    refute has_element?(view, "#new-events")

    matching = insert_finding_event(ctx, "JE-000123", actor: {:agent, "triage:fake-triage-v1"})

    matching_two =
      insert_finding_event(ctx, "JE-000123", actor: {:agent, "triage:fake-triage-v1"})

    for event <- [matching, matching_two], do: :ok = AuditTrail.broadcast_appended(event)
    assert has_element?(view, "#new-events", "새 이벤트 2건")
    assert event_ids(view) == []

    view |> element("#new-events") |> render_click()
    assert event_ids(view) == Enum.map([matching_two, matching], &"audit-event-#{&1.seq}")
    assert selected_actor(view) == ["actor-filter-agent"]
    assert has_element?(view, "#subject-filter[value=JE-000123]")
    refute has_element?(view, "#audit-events-empty")
  end

  test "changing filters clears the new-event counter and reads the current snapshot", ctx do
    insert_event(ctx)
    {:ok, view, _html} = live(ctx.conn, ~p"/engagements/#{ctx.engagement}/audit")
    agent = insert_finding_event(ctx, "JE-000123", actor: {:agent, "triage:fake-triage-v1"})
    :ok = AuditTrail.broadcast_appended(agent)
    assert has_element?(view, "#new-events", "새 이벤트 1건")

    view |> element("#actor-filter-agent") |> render_click()
    assert event_ids(view) == ["audit-event-#{agent.seq}"]
    refute has_element?(view, "#new-events")
  end

  test "loads 50 rows per cursor and hides the button when the final page is short", ctx do
    events = Enum.map(1..105, fn _ -> insert_event(ctx) end)
    expected = events |> Enum.reverse() |> Enum.map(&"audit-event-#{&1.seq}")
    {:ok, view, _html} = live(ctx.conn, ~p"/engagements/#{ctx.engagement}/audit")
    assert event_ids(view) == Enum.take(expected, 50)
    assert has_element?(view, "#load-more", "더 보기")
    refute has_element?(view, "#audit-events-end")

    view |> element("#load-more") |> render_click()
    assert event_ids(view) == Enum.take(expected, 100)
    assert has_element?(view, "#load-more")
    view |> element("#load-more") |> render_click()
    assert event_ids(view) == expected
    refute has_element?(view, "#load-more")
    assert has_element?(view, "#audit-events-end", "처음 기록까지 모두 보았습니다.")

    render_click(view, "load_more")
    assert event_ids(view) == expected
  end

  test "an exactly full page ends after the next empty page and retains the rows", ctx do
    for _ <- 1..50, do: insert_event(ctx)
    {:ok, view, _html} = live(ctx.conn, ~p"/engagements/#{ctx.engagement}/audit")
    before = event_ids(view)
    view |> element("#load-more") |> render_click()
    assert length(before) == 50
    assert event_ids(view) == before
    refute has_element?(view, "#load-more")
    assert has_element?(view, "#audit-events-end")
  end

  test "pagination preserves filters and actor changes reset all previously loaded rows", ctx do
    insert_event(ctx)

    agent_events =
      for _ <- 1..51,
          do: insert_finding_event(ctx, "JE-000123", actor: {:agent, "triage:fake-triage-v1"})

    insert_finding_event(ctx, "JE-OTHER", actor: {:agent, "triage:fake-triage-v1"})

    {:ok, view, _html} =
      live(ctx.conn, ~p"/engagements/#{ctx.engagement}/audit?actor=agent&subject=JE-000123")

    view |> element("#load-more") |> render_click()
    assert event_ids(view) == agent_events |> Enum.reverse() |> Enum.map(&"audit-event-#{&1.seq}")

    view |> element("#actor-filter-system") |> render_click()
    assert event_ids(view) == []
    refute has_element?(view, "#load-more")
  end

  test "optional run filter matches subject type and id for queries and new events", ctx do
    run_id = Ecto.UUID.generate()
    selected = insert_event(ctx, subject_type: "test_run", subject_id: run_id)
    insert_event(ctx, subject_type: "finding", subject_id: run_id)
    insert_event(ctx, subject_type: "test_run", subject_id: Ecto.UUID.generate())
    {:ok, view, _html} = live(ctx.conn, ~p"/engagements/#{ctx.engagement}/audit?run=#{run_id}")
    assert event_ids(view) == ["audit-event-#{selected.seq}"]

    wrong_type = insert_event(ctx, subject_type: "finding", subject_id: run_id)
    wrong_id = insert_event(ctx, subject_type: "test_run", subject_id: Ecto.UUID.generate())
    for event <- [wrong_type, wrong_id], do: :ok = AuditTrail.broadcast_appended(event)
    refute has_element?(view, "#new-events")
    matching = insert_event(ctx, subject_type: "test_run", subject_id: run_id)
    :ok = AuditTrail.broadcast_appended(matching)
    assert has_element?(view, "#new-events", "새 이벤트 1건")

    view |> element("#clear-run-filter") |> render_click()
    assert_patch(view, ~p"/engagements/#{ctx.engagement}/audit")
    assert length(event_ids(view)) == 6
    refute has_element?(view, "#new-events")
  end

  test "unrelated engagement messages do not change the list or stop the view", ctx do
    event = insert_event(ctx)
    {:ok, view, _html} = live(ctx.conn, ~p"/engagements/#{ctx.engagement}/audit")

    for name <- [
          :import_updated,
          :test_run_updated,
          :finding_updated,
          :triage_requested,
          :member_added,
          :rule_progress,
          :run_completed
        ] do
      :ok = Engagements.broadcast(ctx.engagement.id, {name, %{id: Ecto.UUID.generate()}})
    end

    assert event_ids(view) == ["audit-event-#{event.seq}"]
    refute has_element?(view, "#new-events")
  end

  test "reviewers and preparers see the same historical events and no write controls", ctx do
    reviewer = user_fixture()
    insert_member(ctx.engagement, reviewer, :reviewer)
    insert_event(ctx, actor: {:user, reviewer.id}, action: "review.approved")
    other_engagement = insert_engagement(ctx.user)
    insert_member(other_engagement, ctx.user, :preparer)
    hidden_event = insert_event(%{ctx | engagement: other_engagement})
    {:ok, preparer_view, _html} = live(ctx.conn, ~p"/engagements/#{ctx.engagement}/audit")
    reviewer_conn = build_conn() |> log_in_user(reviewer)
    {:ok, reviewer_view, _html} = live(reviewer_conn, ~p"/engagements/#{ctx.engagement}/audit")

    assert event_ids(preparer_view) == event_ids(reviewer_view)
    assert has_element?(reviewer_view, "#audit-events [data-column=actor]", reviewer.email)
    refute has_element?(reviewer_view, row(hidden_event))
    refute has_element?(preparer_view, row(hidden_event))
    assert element_ids(preparer_view, "#s6 button") == element_ids(reviewer_view, "#s6 button")
  end

  defp insert_event(ctx, attrs \\ []) do
    attrs =
      Enum.into(attrs, %{
        engagement_id: ctx.engagement.id,
        actor: AuditTrail.actor(ctx.scope),
        action: "engagement.created",
        subject_type: "engagement",
        subject_id: ctx.engagement.id,
        payload: %{"client_name" => ctx.engagement.client_name, "fiscal_year" => 2025}
      })

    attrs
    |> AuditEvent.changeset()
    |> Ecto.Changeset.put_change(:inserted_at, ~U[2026-10-19 01:02:03.000000Z])
    |> Repo.insert!()
  end

  defp insert_finding_event(ctx, number, attrs \\ []) do
    attrs =
      Keyword.merge(
        [
          action: "ai_triage.requested",
          subject_type: "finding",
          subject_id: Ecto.UUID.generate(),
          payload: %{"entry_number" => number}
        ],
        attrs
      )

    insert_event(ctx, attrs)
  end

  defp row(event), do: "#audit-event-#{event.seq}"

  defp payload_json(view, event) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(row(event) <> " details pre code")
    |> LazyHTML.text()
    |> Jason.decode!()
  end

  defp element_ids(view, selector),
    do:
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("id")

  defp event_ids(view), do: element_ids(view, "#audit-events > li")
  defp selected_actor(view), do: element_ids(view, "#s6 button[aria-pressed=true]")
end
