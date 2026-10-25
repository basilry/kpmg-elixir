defmodule TickmarkWeb.Docs.Document do
  @moduledoc """
  One project document in the docs wiki.

  `id` is the wiki address: `"index"` for docs/README.md, `"readme"`,
  `"tasks"`, `"agents"` for the root files, and the path under docs/ without
  the extension for everything else (`"planning/2026-10-17-2-MVP-범위와-일정"`).

  `body` is rendered HTML for markdown and the file itself for HTML documents.
  `text` is the plain text the sidebar search looks through.
  """

  @enforce_keys [:id, :path, :category, :title, :format, :body, :text]
  defstruct [:id, :path, :category, :title, :date, :seq, :format, :body, :text, toc: []]
end
