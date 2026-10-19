defmodule TickmarkWeb.FindingLive.Components do
  @moduledoc "Small shared display helpers for S5."
  use TickmarkWeb, :html

  alias TickmarkWeb.Format

  attr :value, :any, required: true

  def optional_value(assigns) do
    ~H"""
    <%= if @value in [nil, ""] do %>
      -<span class="sr-only">없음</span>
    <% else %>
      {@value}
    <% end %>
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
