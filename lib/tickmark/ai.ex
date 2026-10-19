defmodule Tickmark.AI do
  @moduledoc """
  Configured AI client and a reproducible fingerprint of triage input.

  The caller supplies normalized input; this module does not change findings or
  persist suggestions. Tests and demos use the same interface with the fake.
  """

  alias Tickmark.AI.Client

  @spec config() :: keyword()
  def config, do: Application.fetch_env!(:tickmark, __MODULE__)

  @spec client() :: module()
  def client, do: config() |> Keyword.fetch!(:client)

  @spec triage(Client.input(), keyword()) :: {:ok, Client.result()} | {:error, Client.error()}
  def triage(input, opts \\ []), do: client().triage(input, opts)

  @doc """
  SHA-256 of JSON with recursively sorted object keys. Array order is preserved.
  """
  @spec input_hash(map()) :: String.t()
  def input_hash(input) when is_map(input) do
    json = input |> ordered_json() |> Jason.encode!()
    :crypto.hash(:sha256, json) |> Base.encode16(case: :lower)
  end

  # Decimal, Date and other JSON-encodable structs keep their own encoders.
  defp ordered_json(value) when is_struct(value), do: value

  defp ordered_json(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), ordered_json(item)} end)
    |> Enum.sort_by(fn {key, _item} -> key end)
    |> Jason.OrderedObject.new()
  end

  defp ordered_json(value) when is_list(value), do: Enum.map(value, &ordered_json/1)
  defp ordered_json(value), do: value
end
