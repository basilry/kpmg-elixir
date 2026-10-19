defmodule TickmarkWeb.ImportLive.Components do
  @moduledoc "Result panels and safe, fixed messages used only by S3."
  use TickmarkWeb, :html

  import TickmarkWeb.EngagementLive.Components, only: [import_source: 1, import_status: 1]
  alias TickmarkWeb.Format

  @issue_messages %{
    "missing_column" => "필수 컬럼이 없습니다",
    "unknown_column" => "알 수 없거나 겹친 컬럼이 있습니다",
    "required" => "필수 값이 비어 있습니다",
    "too_long" => "값이 너무 깁니다",
    "invalid_value" => "허용되지 않는 값입니다",
    "invalid_date" => "날짜 또는 일시 형식이 잘못되었습니다",
    "invalid_number" => "금액은 원 단위 정수여야 합니다",
    "both_sides" => "한 행에는 차변과 대변 중 하나만 있어야 합니다",
    "unbalanced_entry" => "전표의 차변 합계와 대변 합계가 다릅니다",
    "inconsistent_header" => "같은 전표의 헤더 값이 행마다 다릅니다",
    "non_contiguous_entry" => "같은 전표의 행이 이어져 있지 않습니다",
    "duplicate_line_number" => "같은 전표에 같은 라인 번호가 있습니다",
    "too_many_rows" => "행 수가 상한(100,000)을 넘었습니다",
    "parse_error" => "CSV 형식을 읽을 수 없습니다",
    "period_mismatch" => "전기일의 월과 회계기간이 다릅니다"
  }
  @columns Tickmark.Ledger.CsvParser.column_names()
  @no_column_codes ~w(unknown_column both_sides unbalanced_entry too_many_rows)

  attr :ledger_import, :any, required: true
  attr :engagement, :any, required: true

  def import_result(assigns) do
    ~H"""
    <section
      id="s3-result"
      aria-labelledby="s3-result-name"
      class="space-y-4 rounded-box border border-base-300 bg-base-100 p-4"
    >
      <div id="s3-result-1" class="flex flex-wrap items-center justify-between gap-2">
        <div class="flex flex-wrap items-center gap-2">
          <h2 id="s3-result-name" class="font-medium break-all">{import_source(@ledger_import)}</h2>
          <span id="s3-import-status" role="status" aria-live="polite">
            <.import_status status={@ledger_import.status} />
          </span>
        </div>
        <p class="text-xs text-muted">
          <time
            datetime={DateTime.to_iso8601(@ledger_import.inserted_at)}
            title={Format.utc_title(@ledger_import.inserted_at)}
            class="tabular-nums"
          >
            {Format.format_kst(@ledger_import.inserted_at)} KST
          </time>
          , 해시
          <span class="font-mono slashed-zero" title={@ledger_import.sha256}>
            {String.slice(@ledger_import.sha256, 0, 8)}
          </span>
        </p>
      </div>

      <%= case @ledger_import.status do %>
        <% :pending -> %>
          <p id="s3-result-2" class="text-sm text-muted">앞의 적재가 끝나면 시작합니다. 이 화면을 떠나도 계속됩니다.</p>
        <% :processing -> %>
          <p id="s3-result-2" class="flex items-center gap-2 text-sm text-muted">
            <span class="loading loading-dots loading-xs" aria-hidden="true"></span>
            검증하고 적재하는 중입니다. 이 화면을 떠나도 계속됩니다.
          </p>
        <% :failed -> %>
          <div id="s3-result-2" class="alert alert-error" role="alert">
            <.icon name="hero-x-circle" />
            <%= if @ledger_import.error_count > 0 do %>
              <span>GL을 적재하지 못했습니다. 아래 오류 {Format.format_count(@ledger_import.error_count)}건을 고친 뒤 다시 올리세요. 파일의 원래 값은 화면에 다시 쓰지 않습니다.</span>
            <% else %>
              <span>파일을 처리하지 못했습니다. 같은 파일을 다시 올려 주세요. 계속 실패하면 관리자에게 알려 주세요.</span>
            <% end %>
          </div>
          <.issue_table
            :if={@ledger_import.error_count > 0}
            id="s3-result-3"
            issues={@ledger_import.errors}
            count={@ledger_import.error_count}
            caption="적재 오류"
          />
        <% :succeeded -> %>
          <dl id="s3-result-2" class="grid grid-cols-2 gap-3 text-sm">
            <div>
              <dt class="text-muted">전표</dt><dd class="text-2xl tabular-nums">
                {Format.format_count(@ledger_import.entry_count)}<small class="text-sm">건</small>
              </dd>
            </div>
            <div>
              <dt class="text-muted">라인</dt><dd class="text-2xl tabular-nums">
                {Format.format_count(@ledger_import.line_count)}<small class="text-sm">건</small>
              </dd>
            </div>
            <div>
              <dt class="text-muted">차변 합계(원)</dt><dd class="tabular-nums">
                {Format.format_krw(@ledger_import.total_debit)}
              </dd>
            </div>
            <div>
              <dt class="text-muted">대변 합계(원)</dt><dd class="tabular-nums">
                {Format.format_krw(@ledger_import.total_credit)}
              </dd>
            </div>
            <div>
              <dt class="text-muted">경고</dt><dd class="tabular-nums">
                {Format.format_count(@ledger_import.warning_count)}건
              </dd>
            </div>
          </dl>
          <.link
            id="s3-result-next"
            navigate={~p"/engagements/#{@engagement}"}
            class="btn btn-sm btn-primary"
          >
            감사 대상에서 테스트 실행
          </.link>
      <% end %>

      <details :if={@ledger_import.warning_count > 0} id="s3-result-4" class="text-sm">
        <summary class="cursor-pointer py-1">
          경고 {Format.format_count(@ledger_import.warning_count)}건
        </summary>
        <.issue_table
          id="s3-warnings"
          issues={@ledger_import.warnings}
          count={@ledger_import.warning_count}
          caption="적재 경고"
        />
      </details>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :issues, :list, required: true
  attr :count, :integer, required: true
  attr :caption, :string, required: true

  defp issue_table(assigns) do
    # Only contract column names and known codes can reach the HTML. In
    # particular an unknown CSV header or a worker error is never echoed.
    rows = assigns.issues |> Enum.take(100) |> Enum.map(&issue_row/1)
    assigns = assign(assigns, rows: rows, remaining: max(assigns.count - length(rows), 0))

    ~H"""
    <div id={@id} class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
      <table class="table tk-table">
        <caption class="sr-only">{@caption}</caption>
        <thead>
          <tr>
            <th scope="col" class="text-right">행</th><th scope="col">컬럼</th>
            <th scope="col">코드</th><th scope="col">내용</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={{row, index} <- Enum.with_index(@rows, 1)} id={"#{@id}-#{index}"}>
            <td class="text-right tabular-nums">
              {row.line}<span :if={row.line == "-"} class="sr-only">없음</span>
            </td>
            <td class="font-mono whitespace-nowrap">
              {row.field}<span :if={row.field == "-"} class="sr-only">없음</span>
            </td>
            <td class="font-mono whitespace-nowrap">{row.code}</td><td>{row.message}</td>
          </tr>
        </tbody>
      </table>
      <p
        :if={@remaining > 0}
        id={"#{@id}-more"}
        class="border-t border-base-300 p-3 text-sm text-muted"
      >
        그 밖에 {Format.format_count(@remaining)}건
      </p>
    </div>
    """
  end

  defp issue_row(issue) do
    code = issue["code"]
    field = issue["field"]

    %{
      line: if(is_integer(issue["line"]), do: Format.format_count(issue["line"]), else: "-"),
      field: if(field in @columns and code not in @no_column_codes, do: field, else: "-"),
      code: if(Map.has_key?(@issue_messages, code), do: code, else: "-"),
      message: Map.get(@issue_messages, code, "파일을 처리하지 못했습니다")
    }
  end
end
