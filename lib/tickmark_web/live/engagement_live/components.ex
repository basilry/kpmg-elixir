defmodule TickmarkWeb.EngagementLive.Components do
  @moduledoc """
  Small display helpers shared by the S1 and S2 screens.

  The formatting rules follow the design system (6. 금액, 날짜, ID 표기 규칙).
  They live here until a shared `TickmarkWeb.Format` module exists.
  """
  use TickmarkWeb, :html

  alias Tickmark.Engagements.{Engagement, Member}

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
end
