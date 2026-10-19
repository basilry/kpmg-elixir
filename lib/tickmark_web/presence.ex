defmodule TickmarkWeb.Presence do
  @moduledoc """
  Tracks who is looking at an engagement. key = user_id, meta = %{email, role, view}.
  """
  use Phoenix.Presence,
    otp_app: :tickmark,
    pubsub_server: Tickmark.PubSub

  def topic(engagement_id), do: "engagement:#{engagement_id}:presence"
end
