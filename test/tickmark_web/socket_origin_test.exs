defmodule TickmarkWeb.SocketOriginTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Conn, only: [put_req_header: 3]

  alias Phoenix.Socket.Transport

  @render_host "tickmark-e0ki.onrender.com"
  @custom_host "www.tickmark.6esk.com"

  test "production checks the origin against the request" do
    assert prod_endpoint_config()[:check_origin] == :conn
  end

  test "both the Render host and the custom domain open the LiveView socket" do
    for host <- [@render_host, @custom_host] do
      conn = host |> proxied_conn("https://#{host}") |> check_origin(:conn)

      refute conn.halted, "origin rejected for #{host}"
    end
  end

  test "an origin that does not match the request is rejected" do
    for origin <- [
          "https://evil.example",
          "https://#{@custom_host}.evil.example",
          "http://#{@custom_host}"
        ] do
      {conn, log} =
        with_log(fn -> @custom_host |> proxied_conn(origin) |> check_origin(:conn) end)

      assert conn.halted, "origin accepted: #{origin}"
      assert conn.status == 403
      assert log =~ "Could not check origin"
    end
  end

  # The default (true) compares the origin with the endpoint url host only.
  # That is why the custom domain got 403 while url host was the Render host.
  test "the default check rejects a host other than the endpoint url host" do
    capture_log(fn ->
      conn = @custom_host |> proxied_conn("https://#{@custom_host}") |> check_origin(true)

      assert conn.halted
    end)
  end

  # Render ends TLS at its proxy and forwards plain http with
  # x-forwarded-proto. The rewrite uses the production force_ssl options,
  # so the conn looks like the one the socket sees in production.
  defp proxied_conn(host, origin) do
    rewrite_on = Plug.RewriteOn.init(prod_endpoint_config()[:force_ssl][:rewrite_on])

    Plug.Test.conn(:get, "http://#{host}/live/websocket")
    |> put_req_header("x-forwarded-proto", "https")
    |> put_req_header("origin", origin)
    |> Plug.RewriteOn.call(rewrite_on)
  end

  defp check_origin(conn, setting) do
    Transport.check_origin(conn, Phoenix.LiveView.Socket, TickmarkWeb.Endpoint,
      check_origin: setting
    )
  end

  # config/prod.exs reads no environment variables, so the test can load it.
  defp prod_endpoint_config do
    Path.expand("../../config/prod.exs", __DIR__)
    |> Config.Reader.read!(env: :prod)
    |> get_in([:tickmark, TickmarkWeb.Endpoint])
  end
end
