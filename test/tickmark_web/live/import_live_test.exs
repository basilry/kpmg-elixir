defmodule TickmarkWeb.ImportLiveTest do
  use TickmarkWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tickmark.AccountsFixtures
  import Tickmark.EngagementsFixtures
  import Tickmark.LedgerFixtures

  alias Tickmark.{Engagements, Ledger, Repo}
  alias Tickmark.Ledger.{Generator, LedgerImport}

  setup :register_and_log_in_user

  setup %{scope: scope} do
    %{engagement: engagement_fixture(scope)}
  end

  test "uploads a CSV, copies it before consumption, and shows the completed import", ctx do
    %{conn: conn, scope: scope, engagement: engagement} = ctx
    {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}/imports/new")
    assert has_element?(view, "#s3-main-1", "GL 불러오기")
    assert has_element?(view, "#s3-main-3 input[type=file][accept='.csv']")
    assert has_element?(view, "#s3-upload-button[disabled][aria-describedby=s3-why]")

    csv = gl_csv(gl_entry("JE-000001", "1250000"))
    upload_csv(view, csv)
    refute has_element?(view, "#s3-upload-button[disabled]")
    view |> form("#s3-upload-form") |> render_submit()

    assert [imported] = Ledger.list_imports(scope, engagement.id)
    cleanup_import(imported)
    assert imported.original_filename == "gl.csv"
    assert File.read!(stored_path(imported)) == csv
    assert has_element?(view, "#s3-import-status", "대기")
    assert has_element?(view, "#s3-result-name", "gl.csv")

    assert {:ok, %{status: :succeeded}} = Ledger.process_import(imported.id)
    assert has_element?(view, "#s3-import-status", "완료")
    assert has_element?(view, "#s3-result-2", "1,250,000")
    assert has_element?(view, "#s3-result-next[href='/engagements/#{engagement.id}']")
  end

  test "extension and size refusals do not create imports", ctx do
    %{conn: conn, scope: scope, engagement: engagement} = ctx
    {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}/imports/new")

    upload =
      file_input(view, "#s3-upload-form", :ledger, [
        %{name: "gl.txt", content: "csv", type: "text/plain"}
      ])

    assert {:error, _errors} = render_upload(upload, "gl.txt")
    assert has_element?(view, "#s3-upload-form [role=alert]", ".csv 파일만 올릴 수 있습니다.")
    assert has_element?(view, "#s3-upload-button[disabled]")
    view |> element("#s3-upload-form button[phx-click=cancel_upload]") |> render_click()

    upload =
      file_input(view, "#s3-upload-form", :ledger, [
        %{name: "large.csv", content: :binary.copy("x", 20_000_001), type: "text/csv"}
      ])

    assert {:error, _errors} = render_upload(upload, "large.csv")
    assert has_element?(view, "#s3-upload-form [role=alert]", "20MB보다 큰 파일은 올릴 수 없습니다.")
    assert has_element?(view, "#s3-upload-button[disabled]")
    assert Ledger.list_imports(scope, engagement.id) == []
  end

  test "switching source tabs preserves a selected file and selection can be cancelled", ctx do
    %{conn: conn, engagement: engagement} = ctx
    {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}/imports/new")
    upload_csv(view, gl_csv(gl_entry("JE-000001")))
    view |> element("#s3-tab-generated") |> render_click()
    assert_patch(view, ~p"/engagements/#{engagement}/imports/new?source=generated")
    assert has_element?(view, "#s3-gen:not([hidden])")
    view |> element("#s3-tab-upload") |> render_click()
    assert has_element?(view, "#s3-upload-form", "gl.csv")
    view |> element("#s3-upload-form button[phx-click=cancel_upload]") |> render_click()
    assert has_element?(view, "#s3-upload-button[disabled]")
  end

  test "generates a GL using the default seed and accepts an explicit seed", ctx do
    %{conn: conn, scope: scope, engagement: engagement} = ctx
    {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}/imports/new?source=generated")

    view |> form("#s3-gen", sample: %{seed: ""}) |> render_submit()
    assert [default] = Ledger.list_imports(scope, engagement.id)
    cleanup_import(default)
    assert default.source_kind == :generated
    assert default.original_filename == "synthetic-gl-seed-#{Generator.default_seed()}.csv"
    assert has_element?(view, "#s3-result-name", "합성 GL, 시드 #{Generator.default_seed()}")
    assert has_element?(view, "#s3-import-status", "대기")

    view |> form("#s3-gen", sample: %{seed: "42"}) |> render_submit()
    explicit = Enum.find(Ledger.list_imports(scope, engagement.id), &(&1.id != default.id))
    cleanup_import(explicit)
    assert explicit.original_filename == "synthetic-gl-seed-42.csv"
    assert has_element?(view, "#s3-result-name", "합성 GL, 시드 42")
  end

  test "invalid seeds show the fixed field error and do not create an import", ctx do
    %{conn: conn, scope: scope, engagement: engagement} = ctx
    {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}/imports/new?source=generated")
    view |> form("#s3-gen", sample: %{seed: "1.5"}) |> render_submit()
    assert has_element?(view, "#s3-gen-1", "정수로 입력하세요.")
    assert Ledger.list_imports(scope, engagement.id) == []
  end

  test "import_updated rereads only the selected import and displays processing and totals",
       ctx do
    %{conn: conn, scope: scope, engagement: engagement} = ctx
    {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}/imports/new")
    upload_csv(view, gl_csv(gl_entry("JE-000001")))
    view |> form("#s3-upload-form") |> render_submit()
    [imported] = Ledger.list_imports(scope, engagement.id)
    cleanup_import(imported)

    imported = imported |> LedgerImport.processing_changeset(DateTime.utc_now()) |> Repo.update!()
    broadcast_import(imported)
    assert has_element?(view, "#s3-import-status", "적재 중")
    assert has_element?(view, "#s3-result-2", "검증하고 적재하는 중입니다.")

    imported =
      imported
      |> LedgerImport.succeeded_changeset(
        %{
          entry_count: 1234,
          line_count: 2468,
          total_debit: Decimal.new("1000000"),
          total_credit: Decimal.new("1000000"),
          warning_count: 0,
          warnings: []
        },
        DateTime.utc_now()
      )
      |> Repo.update!()

    broadcast_import(imported)
    assert has_element?(view, "#s3-import-status", "완료")
    assert has_element?(view, "#s3-result-2", "1,234")
    assert has_element?(view, "#s3-result-2", "2,468")
    broadcast_import(%{imported | id: Ecto.UUID.generate(), status: :failed})
    assert has_element?(view, "#s3-import-status", "완료")
  end

  test "error and warning tables use fixed Korean messages and suppress original values", ctx do
    %{conn: conn, scope: scope, engagement: engagement} = ctx
    {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}/imports/new")
    upload_csv(view, gl_csv(gl_entry("JE-000001")))
    view |> form("#s3-upload-form") |> render_submit()
    [imported] = Ledger.list_imports(scope, engagement.id)
    cleanup_import(imported)

    messages = [
      {"missing_column", "필수 컬럼이 없습니다"},
      {"unknown_column", "알 수 없거나 겹친 컬럼이 있습니다"},
      {"required", "필수 값이 비어 있습니다"},
      {"too_long", "값이 너무 깁니다"},
      {"invalid_value", "허용되지 않는 값입니다"},
      {"invalid_date", "날짜 또는 일시 형식이 잘못되었습니다"},
      {"invalid_number", "금액은 원 단위 정수여야 합니다"},
      {"both_sides", "한 행에는 차변과 대변 중 하나만 있어야 합니다"},
      {"unbalanced_entry", "전표의 차변 합계와 대변 합계가 다릅니다"},
      {"inconsistent_header", "같은 전표의 헤더 값이 행마다 다릅니다"},
      {"non_contiguous_entry", "같은 전표의 행이 이어져 있지 않습니다"},
      {"duplicate_line_number", "같은 전표에 같은 라인 번호가 있습니다"},
      {"too_many_rows", "행 수가 상한(100,000)을 넘었습니다"},
      {"parse_error", "CSV 형식을 읽을 수 없습니다"}
    ]

    errors =
      messages
      |> Stream.cycle()
      |> Enum.take(100)
      |> Enum.with_index(1)
      |> Enum.map(fn {{code, _message}, line} ->
        %{
          "line" => line,
          "field" => if(code == "unknown_column", do: "PRIVATE-HEADER", else: "entered_at"),
          "code" => code,
          "message" => "PRIVATE-RAW-VALUE"
        }
      end)

    imported =
      imported
      |> LedgerImport.failed_changeset(%{errors: errors, error_count: 105}, DateTime.utc_now())
      |> Ecto.Changeset.change(
        warnings: [
          %{
            "line" => 7410,
            "field" => "fiscal_period",
            "code" => "period_mismatch",
            "value" => "PRIVATE-RAW-VALUE"
          }
        ],
        warning_count: 1
      )
      |> Repo.update!()

    broadcast_import(imported)

    assert has_element?(view, "#s3-result-2", "아래 오류 105건을 고친 뒤 다시 올리세요.")

    for {code, message} <- messages do
      assert has_element?(view, "#s3-result-3 td", code)
      assert has_element?(view, "#s3-result-3 td", message)
    end

    assert has_element?(view, "#s3-result-3-more", "그 밖에 5건")
    assert has_element?(view, "#s3-result-4:not([open]) summary", "경고 1건")
    assert has_element?(view, "#s3-warnings", "전기일의 월과 회계기간이 다릅니다")
    refute render(view) =~ "PRIVATE-"
  end

  test "system failures show a fixed message without an error table", ctx do
    %{conn: conn, scope: scope, engagement: engagement} = ctx
    {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}/imports/new")
    upload_csv(view, gl_csv(gl_entry("JE-000001")))
    view |> form("#s3-upload-form") |> render_submit()
    [imported] = Ledger.list_imports(scope, engagement.id)
    cleanup_import(imported)

    imported =
      imported
      |> LedgerImport.failed_changeset(%{errors: [], error_count: 0}, DateTime.utc_now())
      |> Repo.update!()

    broadcast_import(imported)
    assert has_element?(view, "#s3-result-2", "파일을 처리하지 못했습니다. 같은 파일을 다시 올려 주세요.")
    refute has_element?(view, "#s3-result-3")
  end

  test "a reviewer sees the denied state and forged submit events are refused", %{
    conn: conn,
    scope: scope
  } do
    creator = user_scope_fixture()
    engagement = engagement_fixture(creator)
    member_fixture(creator, engagement, :reviewer, scope.user)
    {:ok, view, _html} = live(conn, ~p"/engagements/#{engagement}/imports/new")
    assert has_element?(view, "#s3-forbidden", "GL을 불러올 권한이 없습니다.")
    refute has_element?(view, "#s3-upload-form")
    refute has_element?(view, "#s3-gen")
    render_hook(view, "save", %{})
    render_hook(view, "generate", %{"sample" => %{"seed" => "42"}})
    assert has_element?(view, "#flash-error", "GL을 불러올 권한이 없습니다.")
    assert Ledger.list_imports(creator, engagement.id) == []
  end

  test "a non-member gets the same not-found behavior", %{conn: conn} do
    engagement = engagement_fixture(user_scope_fixture())

    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/engagements/#{engagement}/imports/new")
    end
  end

  defp upload_csv(view, content) do
    upload =
      file_input(view, "#s3-upload-form", :ledger, [
        %{name: "gl.csv", content: content, type: "text/csv"}
      ])

    render_upload(upload, "gl.csv")
  end

  defp broadcast_import(imported) do
    Phoenix.PubSub.broadcast(
      Tickmark.PubSub,
      Engagements.topic(imported.engagement_id),
      {:import_updated,
       %{
         import_id: imported.id,
         status: imported.status,
         entry_count: imported.entry_count,
         error_count: imported.error_count
       }}
    )
  end

  defp cleanup_import(imported) do
    path = stored_path(imported)

    on_exit(fn ->
      File.rm(path)
      File.rm(Path.rootname(path) <> ".labels.csv")
    end)
  end
end
