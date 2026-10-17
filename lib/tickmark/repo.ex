defmodule Tickmark.Repo do
  use Ecto.Repo,
    otp_app: :tickmark,
    adapter: Ecto.Adapters.Postgres
end
