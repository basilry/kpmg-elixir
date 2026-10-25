defmodule Tickmark.Testing.Rule do
  @moduledoc """
  The contract every journal entry test rule implements (design doc 2.2).

  A rule reads one ledger import and returns the entries it flags. It never
  writes: Testing stores the hits and fills each hit's score with `weight/0`.
  Rules are registered by hand in `Tickmark.Testing.Rules`.
  """

  @type hit :: %{
          journal_entry_id: Ecto.UUID.t(),
          # One line a person reads, in Korean.
          reason: String.t(),
          # Evidence from the domain doc. String keys, JSON-safe values.
          details: map()
        }

  @callback id() :: String.t()
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback weight() :: pos_integer()
  @callback default_params() :: map()
  @callback run(Tickmark.Testing.RuleContext.t()) ::
              {:ok, [hit()]} | {:skip, reason :: String.t()} | {:error, term()}

  @doc """
  An amount for `details`, as a whole-won string ("1000000"). Amount columns
  have scale 2, so `Decimal.to_string/1` alone would give "1000000.00".
  Domain doc 4.1 sends amounts to the AI as integer strings; evidence uses
  the same form.
  """
  @spec amount_string(Decimal.t()) :: String.t()
  def amount_string(%Decimal{} = amount) do
    amount |> Decimal.round(0) |> Decimal.to_string(:normal)
  end
end
