defmodule TickmarkWeb.EngagementLive.Components do
  @moduledoc """
  Small display helpers shared by the S1 and S2 screens.

  The formatting rules follow the design system (6. 금액, 날짜, ID 표기 규칙).
  They live here until a shared `TickmarkWeb.Format` module exists.
  """
  use TickmarkWeb, :html

  alias Tickmark.Engagements.{Engagement, Member}
  alias Tickmark.Ledger.LedgerImport

  @doc """
  The caller's role on an engagement loaded by `Tickmark.Engagements`, whose
  `members` holds only the caller's membership.
  """
  def my_role(%Engagement{members: [%Member{role: role}]}), do: role

  def role_label(:preparer), do: "작성자"
  def role_label(:reviewer), do: "검토자"

  def fiscal_year_label(year) when is_integer(year), do: "FY#{year}"

  @doc """
  Formats a KRW amount for tables: thousands separators, no currency symbol.
  A zero fraction is dropped; any other fraction is shown with 2 digits so
  odd data stays visible.
  """
  def format_krw(amount) when is_integer(amount), do: format_krw(Decimal.new(amount))

  def format_krw(%Decimal{} = amount) do
    rounded = Decimal.round(amount, 2)
    sign = if Decimal.negative?(rounded), do: "-", else: ""

    [whole, fraction] =
      rounded
      |> Decimal.abs()
      |> Decimal.to_string(:normal)
      |> String.split(".")

    case fraction do
      "00" -> sign <> group_thousands(whole)
      _ -> sign <> group_thousands(whole) <> "." <> fraction
    end
  end

  @doc "Formats a count with thousands separators."
  def format_count(count) when is_integer(count), do: group_thousands(Integer.to_string(count))

  @doc """
  A UTC timestamp as KST `YYYY-MM-DD HH:MM`. Korea has had no daylight saving
  since 1988, so a fixed +9 hours is exact and no time zone database is needed.
  """
  def format_kst(%DateTime{} = utc) do
    utc |> DateTime.add(9, :hour) |> Calendar.strftime("%Y-%m-%d %H:%M")
  end

  attr :at, DateTime, required: true

  @doc "KST on screen, the UTC original in `datetime` and the tooltip (design doc 6)."
  def kst_time(assigns) do
    ~H"""
    <time datetime={DateTime.to_iso8601(@at)} title={DateTime.to_iso8601(@at)} class="tabular-nums">
      {format_kst(@at)}
    </time>
    """
  end

  @doc """
  Where an import came from: the uploaded file name, or the generator seed,
  which `Tickmark.Ledger.generate_sample_import/3` keeps in the file name.
  """
  def import_source(%LedgerImport{
        source_kind: :generated,
        original_filename: "synthetic-gl-seed-" <> rest
      }),
      do: "합성 GL, 시드 " <> Path.rootname(rest)

  def import_source(%LedgerImport{original_filename: filename}), do: filename

  # GL import status: label, icon and text color (design doc 3.2).
  @import_statuses %{
    pending: {"대기", "hero-clock", "text-base-content/70"},
    processing: {"적재 중", "hero-arrow-path", "text-primary"},
    succeeded: {"완료", "hero-check", "text-success"},
    failed: {"실패", "hero-x-circle", "text-error"}
  }

  attr :status, :atom, required: true, values: Map.keys(@import_statuses)

  def import_status(assigns) do
    {label, icon, color} = Map.fetch!(@import_statuses, assigns.status)
    assigns = assign(assigns, label: label, icon: icon, color: color)

    ~H"""
    <span class={["inline-flex items-center gap-1 text-sm whitespace-nowrap", @color]}>
      <.icon name={@icon} class={["size-4", @status == :processing && "motion-safe:animate-spin"]} />
      {@label}
    </span>
    """
  end

  defp group_thousands(digits) do
    digits
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  attr :role, :atom, required: true

  def role_badge(assigns) do
    ~H"""
    <span class="badge badge-sm badge-outline badge-neutral">{role_label(@role)}</span>
    """
  end

  @doc """
  Summary numbers in a row (design system `stat_row/1`). Each item has
  `:label` and `:value`, and may have `:unit` and `:hint`. A nil value
  shows `-`.
  """
  attr :id, :string, required: true
  attr :items, :list, required: true

  def stat_row(assigns) do
    ~H"""
    <dl id={@id} class="grid grid-cols-2 gap-3 lg:grid-cols-5">
      <div
        :for={item <- @items}
        class="rounded-box border border-base-300 bg-base-100 p-3"
      >
        <dt class="text-xs text-base-content/70">{item.label}</dt>
        <dd :if={item.value} class="text-2xl font-semibold tabular-nums">
          {item.value}<small
            :if={item[:unit]}
            class="ml-1 text-sm font-normal text-base-content/70"
          >{item.unit}</small>
        </dd>
        <dd :if={!item.value} class="text-2xl text-base-content/70">
          -<span class="sr-only">없음</span>
        </dd>
        <dd :if={item[:hint]} class="text-xs text-base-content/70">{item.hint}</dd>
      </div>
    </dl>
    """
  end
end
