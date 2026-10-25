defmodule TickmarkWeb.FindingLive.Components do
  @moduledoc "Small shared display helpers for S5."
  use TickmarkWeb, :html

  alias TickmarkWeb.Format

  attr :value, :any, required: true

  # Two clauses instead of an if block: text inside an if block keeps its
  # indentation, which shows up under whitespace-pre-wrap.
  def optional_value(%{value: value} = assigns) when value in [nil, ""] do
    ~H"""
    -<span class="sr-only">없음</span>
    """
  end

  def optional_value(assigns) do
    ~H"""
    {@value}
    """
  end

  attr :value, :any, required: true

  def money(assigns) do
    ~H"""
    <%= if Decimal.equal?(@value, 0) do %>
      -<span class="sr-only">0</span>
    <% else %>
      {Format.format_krw(@value)}
    <% end %>
    """
  end
end
