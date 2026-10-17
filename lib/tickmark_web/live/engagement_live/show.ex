defmodule TickmarkWeb.EngagementLive.Show do
  @moduledoc """
  Placeholder for screen S2 so the router compiles. 10/18 Worker A replaces this file.
  """
  use TickmarkWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <p>감사 대상 개요 화면은 준비 중입니다.</p>
    </Layouts.app>
    """
  end
end
