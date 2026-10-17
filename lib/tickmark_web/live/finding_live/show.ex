defmodule TickmarkWeb.FindingLive.Show do
  @moduledoc """
  Placeholder for screen S5 so the router compiles. 10/20 Worker C replaces this file.
  """
  use TickmarkWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <p>전표 검토 화면은 준비 중입니다.</p>
    </Layouts.app>
    """
  end
end
