defmodule Tickmark.AI.Anthropic do
  @moduledoc """
  Messages API adapter. It validates suggestions and classifies failures, leaving
  persistence, audit events and retry scheduling to the Triage context and worker.
  """
  @behaviour Tickmark.AI.Client

  alias Tickmark.AI.Prompts.Triage

  @output_keys ~w(risk_level rationale suggested_procedures missing_information)
  @procedure_keys ~w(procedure evidence_to_obtain)
  @risk_levels %{"low" => :low, "medium" => :medium, "high" => :high}

  @forbidden_expressions [
    # "없는지/없다면"을 제외하고 이상이나 문제가 없다는 단정을 막는다.
    ~r/(이상|문제)(이|가)?없(음|습니다|다(?!면)|으므로)/u,
    # "예외로 판단"은 도메인에서 활용형과 무관하게 금지한 표현이다.
    ~r/예외(로|라고)?(판단|결론|확정)/u,
    # 승인이나 반려 의견을 막되 "승인 대상 금액/가능 한도"는 허용한다.
    ~r/(승인|반려)(을|를)?(권고|추천|제안|의견|결정|판단|확정|해야|하여야|하라|하자|하세요|합니다|한다|하십시오|됩니다)/u,
    # 평가의 단정형을 막고 "필요한/적절한/하다면" 같은 절차 문구는 허용한다.
    ~r/(승인|반려)(이|가)?(필요|적절|타당)(합니다|하다(?!면)|함|하므로)/u,
    # 승인이나 반려의 명시적인 실행 요구와 처리 결과를 막는다.
    ~r/(승인|반려)(되어야|했습니다|했다|하였|하기를|하길|할것을|할수있|해도)/u,
    # 의견 전체가 단일 승인 또는 반려인 경우도 막는다.
    ~r/^(승인|반려)$/u,
    # 부정이나 횡령을 확정하거나 특정인의 행위로 단정하는 표현을 막는다.
    ~r/(부정|횡령)(거래|행위|사건)?(으로|로|이라고|라고|임이|임을|이|가|을|를)?(판단|결론|확정|단정|명백|확실|확인되|확인됐|입니다|이다|에해당|발생했|발생하였|저질렀|저지른|적발되었|했다|하였다|했습니다)/u
  ]

  @impl true
  def triage(input, _opts \\ []) do
    cfg = Tickmark.AI.config()

    case cfg[:api_key] do
      api_key when is_binary(api_key) and byte_size(api_key) > 0 ->
        input
        |> request_options(cfg)
        |> Req.post()
        |> handle_response()

      _ ->
        {:error, {:fatal, :missing_api_key}}
    end
  end

  defp request_options(input, cfg) do
    body = %{
      model: Keyword.fetch!(cfg, :model),
      max_tokens: Keyword.fetch!(cfg, :max_tokens),
      system: Triage.system(),
      messages: [%{role: "user", content: Triage.user_message(input)}],
      output_config: %{
        effort: Keyword.fetch!(cfg, :effort),
        format: %{type: "json_schema", schema: Triage.output_schema()}
      }
    }

    {body, beta_headers} =
      if cfg[:server_side_fallbacks] do
        {Map.put(body, :fallbacks, "default"),
         [{"anthropic-beta", "server-side-fallback-2026-07-01"}]}
      else
        {body, []}
      end

    [
      url: "https://api.anthropic.com/v1/messages",
      json: body,
      headers: [{"x-api-key", cfg[:api_key]}, {"anthropic-version", "2023-06-01"}] ++ beta_headers
    ]
    |> Keyword.merge(cfg[:req_options] || [])
    |> Keyword.merge(
      retry: false,
      receive_timeout: 120_000,
      redirect: false,
      decode_body: false
    )
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}) do
    case decode_json(body) do
      {:ok, %{"stop_reason" => "end_turn"} = message} -> parse_message(message)
      {:ok, %{"stop_reason" => "max_tokens"}} -> {:error, {:retryable, :max_tokens}}
      {:ok, %{"stop_reason" => "refusal"}} -> {:error, {:fatal, :refusal}}
      _ -> invalid_output()
    end
  end

  defp handle_response({:ok, %Req.Response{status: 429} = response}) do
    retry_after =
      case Req.Response.get_header(response, "retry-after") do
        [value] ->
          case Integer.parse(String.trim(value)) do
            {seconds, ""} when seconds > 0 -> seconds
            _ -> nil
          end

        _ ->
          nil
      end

    {:error, {:rate_limited, retry_after}}
  end

  defp handle_response({:ok, %Req.Response{status: status}}) when status in 500..599 do
    {:error, {:retryable, {:http_status, status}}}
  end

  defp handle_response({:ok, %Req.Response{status: status}}) do
    {:error, {:fatal, {:http_status, status}}}
  end

  # Never return the request, response body, or raw exception: they can contain
  # credentials or untrusted text. Retries only need a stable failure category.
  defp handle_response({:error, _error}), do: {:error, {:retryable, :transport_error}}

  defp decode_json(body) when is_binary(body), do: Jason.decode(body)
  defp decode_json(body) when is_map(body), do: {:ok, body}
  defp decode_json(_body), do: :error

  defp parse_message(%{
         "content" => content,
         "model" => model,
         "usage" => %{"input_tokens" => input_tokens, "output_tokens" => output_tokens}
       })
       when is_list(content) and is_binary(model) and byte_size(model) > 0 and
              is_integer(input_tokens) and input_tokens >= 0 and
              is_integer(output_tokens) and output_tokens >= 0 do
    text =
      Enum.map_join(content, fn
        %{"type" => "text", "text" => text} when is_binary(text) -> text
        _ -> ""
      end)

    with {:ok, output} <- Jason.decode(text),
         {:ok, result} <- validate_output(output) do
      {:ok,
       Map.merge(result, %{
         response_model: model,
         stop_reason: "end_turn",
         input_tokens: input_tokens,
         output_tokens: output_tokens
       })}
    else
      _ -> invalid_output()
    end
  end

  defp parse_message(_message), do: invalid_output()

  defp validate_output(
         %{
           "risk_level" => risk_level,
           "rationale" => rationale,
           "suggested_procedures" => procedures,
           "missing_information" => missing
         } = output
       ) do
    valid? =
      exact_keys?(output, @output_keys) and Map.has_key?(@risk_levels, risk_level) and
        text?(rationale) and is_list(procedures) and length(procedures) in 1..4 and
        Enum.all?(procedures, &valid_procedure?/1) and is_list(missing) and length(missing) <= 5 and
        Enum.all?(missing, &text?/1)

    if valid? and allowed_text?(rationale, procedures, missing) do
      {:ok,
       %{
         risk_level: Map.fetch!(@risk_levels, risk_level),
         rationale: String.slice(rationale, 0, 600),
         suggested_procedures:
           Enum.map(procedures, fn item ->
             %{procedure: item["procedure"], evidence_to_obtain: item["evidence_to_obtain"]}
           end),
         missing_information: missing
       }}
    else
      invalid_output()
    end
  end

  defp validate_output(_output), do: invalid_output()

  defp valid_procedure?(%{"procedure" => procedure, "evidence_to_obtain" => evidence} = item) do
    exact_keys?(item, @procedure_keys) and text?(procedure) and text?(evidence)
  end

  defp valid_procedure?(_item), do: false

  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp text?(value), do: is_binary(value) and String.trim(value) != ""

  defp allowed_text?(rationale, procedures, missing) do
    texts =
      [rationale | missing] ++
        Enum.flat_map(procedures, &[&1["procedure"], &1["evidence_to_obtain"]])

    Enum.all?(texts, fn text ->
      normalized = text |> String.normalize(:nfkc) |> String.replace(~r/[\s\p{P}\p{S}]+/u, "")
      not Enum.any?(@forbidden_expressions, &Regex.match?(&1, normalized))
    end)
  end

  defp invalid_output, do: {:error, {:fatal, :invalid_output}}
end
