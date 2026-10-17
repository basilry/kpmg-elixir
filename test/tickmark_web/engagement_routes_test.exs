defmodule TickmarkWeb.EngagementRoutesTest do
  use TickmarkWeb.ConnCase, async: true

  # Every engagement screen sits behind login. Membership is checked deeper,
  # in the contexts, and is tested there.
  @paths [
    "/engagements",
    "/engagements/new",
    "/engagements/#{Ecto.UUID.generate()}",
    "/engagements/#{Ecto.UUID.generate()}/imports/new",
    "/engagements/#{Ecto.UUID.generate()}/runs/#{Ecto.UUID.generate()}",
    "/engagements/#{Ecto.UUID.generate()}/findings/#{Ecto.UUID.generate()}",
    "/engagements/#{Ecto.UUID.generate()}/audit"
  ]

  test "redirect to log in when not authenticated", %{conn: conn} do
    for path <- @paths do
      assert redirected_to(get(conn, path)) == ~p"/users/log-in", path
    end
  end
end
