defmodule Tickmark.Config.RuntimeTest do
  # Reads config/runtime.exs the way a production boot does. It changes OS
  # environment variables, so it must not run alongside other tests.
  use ExUnit.Case, async: false

  @runtime_config "config/runtime.exs"
  @render_host "tickmark-e0ki.onrender.com"

  # Dummy values that only get runtime.exs through its prod checks.
  @required %{
    "DATABASE_URL" => "ecto://user:pass@localhost/tickmark_config_check",
    "SECRET_KEY_BASE" => String.duplicate("x", 64)
  }

  setup do
    names = Map.keys(@required) ++ ["PHX_HOST", "RENDER_EXTERNAL_HOSTNAME"]
    saved = Map.new(names, &{&1, System.get_env(&1)})
    on_exit(fn -> put_env(saved) end)

    System.put_env(@required)
    :ok
  end

  test "allows both the custom domain and the Render address" do
    config =
      prod_endpoint(%{
        "PHX_HOST" => "tickmark.6esk.com",
        "RENDER_EXTERNAL_HOSTNAME" => @render_host
      })

    assert config[:url][:host] == "tickmark.6esk.com"
    assert config[:check_origin] == ["https://tickmark.6esk.com", "https://#{@render_host}"]
  end

  test "without PHX_HOST, uses the Render address once" do
    config = prod_endpoint(%{"PHX_HOST" => nil, "RENDER_EXTERNAL_HOSTNAME" => @render_host})

    assert config[:url][:host] == @render_host
    assert config[:check_origin] == ["https://#{@render_host}"]
  end

  test "outside Render, allows only PHX_HOST" do
    config =
      prod_endpoint(%{"PHX_HOST" => "tickmark.6esk.com", "RENDER_EXTERNAL_HOSTNAME" => nil})

    assert config[:check_origin] == ["https://tickmark.6esk.com"]
  end

  defp prod_endpoint(env) do
    put_env(env)

    @runtime_config
    |> Config.Reader.read!(env: :prod)
    |> get_in([:tickmark, TickmarkWeb.Endpoint])
  end

  # A nil value means the variable is unset.
  defp put_env(env) do
    Enum.each(env, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end
end
