defmodule TickmarkWeb.FindingLive.EntryPanels do
  @moduledoc "Original journal entry facts and lines."
  use TickmarkWeb, :html

  import TickmarkWeb.FindingLive.Components
  alias TickmarkWeb.Format

  attr :entry, :any, required: true
  attr :description, :string, default: nil

  def entry_facts(assigns) do
    ~H"""
    <section
      id="entry-facts"
      aria-labelledby="entry-facts-title"
      class="space-y-3 rounded-box border border-base-300 bg-base-100 p-4"
    >
      <h2 id="entry-facts-title" class="font-semibold">전표 사실</h2>
      <dl class="grid grid-cols-2 gap-x-6 gap-y-3 sm:grid-cols-3">
        <div>
          <dt class="text-xs text-muted">전기일</dt><dd class="tabular-nums">
            {Format.format_date(@entry.posting_date)}
          </dd>
        </div>
        <div>
          <dt class="text-xs text-muted">증빙일</dt><dd class="tabular-nums">
            {Format.format_date(@entry.document_date)}
          </dd>
        </div>
        <div>
          <dt class="text-xs text-muted">입력 일시 (KST)</dt><dd class="tabular-nums">
            {Format.format_kst(@entry.entered_at, :second)}
          </dd>
        </div>
        <div>
          <dt class="text-xs text-muted">회계기간</dt><dd>
            {if @entry.fiscal_period == 13, do: "13(결산조정)", else: @entry.fiscal_period}
          </dd>
        </div>
        <div>
          <dt class="text-xs text-muted">입력자</dt><dd class="font-mono break-all">
            {@entry.entered_by}
          </dd>
        </div>
        <div>
          <dt class="text-xs text-muted">승인자</dt>
          <dd class="flex flex-wrap items-center gap-1">
            <span class="font-mono break-all"><.optional_value value={@entry.approved_by} /></span>
            <span
              :if={@entry.approved_by && @entry.approved_by == @entry.entered_by}
              id="entry-self-approved"
              class="inline-flex items-center text-warning"
            >
              <.icon name="hero-exclamation-triangle" class="size-4" /><span class="sr-only">입력자와 같음</span>
            </span>
          </dd>
        </div>
        <div>
          <dt class="text-xs text-muted">구분</dt><dd>
            {if @entry.source == :manual, do: "수기", else: "자동"}
          </dd>
        </div>
        <div>
          <dt class="text-xs text-muted">거래처</dt><dd
            id="entry-counterparty"
            class="break-words"
          >
            <.optional_value value={@entry.counterparty} />
          </dd>
        </div>
        <div class="col-span-full">
          <dt class="text-xs text-muted">적요</dt><dd
            id="entry-description"
            class="break-words"
          >
            <.optional_value value={@description} />
          </dd>
        </div>
      </dl>
    </section>
    """
  end

  attr :rows, :any, required: true
  attr :number, :string, required: true
  attr :total_debit, :any, required: true
  attr :total_credit, :any, required: true
  attr :balanced, :boolean, required: true

  def entry_lines(assigns) do
    ~H"""
    <section aria-labelledby="entry-lines-title" class="space-y-2">
      <h2 id="entry-lines-title" class="font-semibold">전표 행</h2>
      <div class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
        <table id="entry-lines" class="table tk-table">
          <caption class="sr-only">{@number} 전표 행</caption>
          <thead>
            <tr>
              <th scope="col" class="hidden sm:table-cell">행</th><th scope="col">계정</th>
              <th scope="col" class="hidden sm:table-cell">적요</th>
              <th scope="col" class="text-right">차변(원)</th><th scope="col" class="text-right">
                대변(원)
              </th>
            </tr>
          </thead>
          <tbody id="entry-line-rows" phx-update="stream">
            <tr :for={{id, line} <- @rows} id={id}>
              <td class="hidden font-mono sm:table-cell">L{line.line_number}</td>
              <td><span class="font-mono">{line.account_code}</span> {line.account_name}</td>
              <td class="hidden break-words sm:table-cell">
                <.optional_value value={line.description} />
              </td>
              <td class="text-right tabular-nums whitespace-nowrap"><.money value={line.debit} /></td>
              <td class="text-right tabular-nums whitespace-nowrap">
                <.money value={line.credit} />
              </td>
            </tr>
          </tbody>
          <tfoot>
            <tr id="entry-lines-total">
              <th scope="row">
                <span class="sr-only">합계, </span><span class={[
                  @balanced && "text-success",
                  !@balanced && "text-error"
                ]}>
                  <.icon
                    name={if @balanced, do: "hero-check-circle", else: "hero-exclamation-circle"}
                    class="size-4"
                  />
                  {if @balanced, do: "차대 일치", else: "차대 불일치"}
                </span>
              </th>
              <td class="hidden sm:table-cell"></td><td class="hidden sm:table-cell"></td>
              <td class="text-right tabular-nums"><.money value={@total_debit} /></td>
              <td class="text-right tabular-nums"><.money value={@total_credit} /></td>
            </tr>
          </tfoot>
        </table>
      </div>
    </section>
    """
  end
end
