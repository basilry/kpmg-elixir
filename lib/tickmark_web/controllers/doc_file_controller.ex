defmodule TickmarkWeb.DocFileController do
  @moduledoc """
  Serves the HTML design documents that the docs wiki shows in a frame.

  Only catalogued HTML documents are served; the URL path is a lookup key,
  never a file path. The files run their own scripts, so the sandbox policy
  gives them an opaque origin: they cannot read this app's cookies or
  storage, even when opened directly in a tab.
  """
  use TickmarkWeb, :controller

  alias TickmarkWeb.Docs
  alias TickmarkWeb.Docs.NotFoundError

  @csp "sandbox allow-scripts; frame-ancestors 'self'; base-uri 'none'"

  def show(conn, %{"path" => segments}) do
    case Docs.html_file(Enum.join(["docs" | segments], "/")) do
      nil ->
        raise NotFoundError

      body ->
        conn
        |> put_resp_header("content-security-policy", @csp)
        |> put_resp_content_type("text/html")
        |> send_resp(200, body)
    end
  end
end
