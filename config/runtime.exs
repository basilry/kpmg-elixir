import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/tickmark start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :tickmark, TickmarkWeb.Endpoint, server: true
end

config :tickmark, TickmarkWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Uploaded and generated GL files. The DB stores only names relative to this.
config :tickmark,
       :import_dir,
       System.get_env("TICKMARK_IMPORT_DIR") ||
         Path.join(System.tmp_dir!(), "tickmark_imports")

# The API key is read only here. Tests never pick it up, so a key in the
# developer's shell cannot make the test suite call the real API.
if config_env() != :test do
  if api_key = System.get_env("ANTHROPIC_API_KEY") do
    config :tickmark, Tickmark.AI,
      client: Tickmark.AI.Anthropic,
      api_key: api_key,
      model: System.get_env("ANTHROPIC_MODEL", "claude-opus-5-5")
  end

  # Password for the two demo users that Tickmark.Demo creates. Without it they
  # can only log in by magic link, and production sends no mail.
  config :tickmark, :demo_password, System.get_env("TICKMARK_DEMO_PASSWORD")
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :tickmark, TickmarkWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/tickmark_web/router\.ex$"E,
        ~r"lib/tickmark_web/(controllers|live|components)/.*\.(ex|heex)$"E,
        # Project documents shown in the docs wiki
        ~r"docs/.*\.(md|html)$"E,
        ~r"(README|TASKS|AGENTS)\.md$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :tickmark, Tickmark.Repo,
    # Neon requires TLS. Postgrex verifies the certificate and host name.
    # DATABASE_SSL=false is only for running the image against a local DB.
    ssl: System.get_env("DATABASE_SSL") != "false",
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # Render sets RENDER_EXTERNAL_HOSTNAME. The LiveView socket checks the
  # origin against this host, so a wrong value breaks every live page.
  host =
    System.get_env("PHX_HOST") || System.get_env("RENDER_EXTERNAL_HOSTNAME") || "example.com"

  # The free host has no shell, so the release seeds the demo itself
  # (Tickmark.Demo). It does nothing once the demo data exists.
  config :tickmark, :seed_demo_on_boot, System.get_env("TICKMARK_SEED_ON_BOOT") in ~w(true 1)

  config :tickmark, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :tickmark, TickmarkWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :tickmark, TickmarkWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :tickmark, TickmarkWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :tickmark, Tickmark.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
