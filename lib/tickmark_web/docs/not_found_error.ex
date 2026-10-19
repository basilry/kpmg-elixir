defmodule TickmarkWeb.Docs.NotFoundError do
  @moduledoc "Raised for a wiki address that is not in the catalog. Plug turns it into a 404."
  defexception message: "document not found", plug_status: 404
end
