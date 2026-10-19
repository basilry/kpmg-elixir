defmodule Tickmark.AI.Client do
  @moduledoc """
  Contract for proposing triage, without making an audit decision.

  Clients classify failures; the Oban worker owns retries and rate-limit waits.
  """

  @type input :: map()
  @type result :: %{
          risk_level: :low | :medium | :high,
          rationale: String.t(),
          suggested_procedures: [
            %{procedure: String.t(), evidence_to_obtain: String.t()}
          ],
          missing_information: [String.t()],
          response_model: String.t(),
          stop_reason: String.t(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer()
        }
  @type error ::
          {:rate_limited, pos_integer() | nil}
          | {:retryable, term()}
          | {:fatal, term()}

  @callback triage(input(), keyword()) :: {:ok, result()} | {:error, error()}
end
