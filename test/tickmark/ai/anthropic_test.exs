defmodule Tickmark.AI.AnthropicTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Tickmark.AI
  alias Tickmark.AI.Anthropic
  alias Tickmark.AI.Prompts.Triage

  setup {Req.Test, :verify_on_exit!}

  setup do
    cfg = AI.config()
    assert cfg[:req_options][:plug] == {Req.Test, Anthropic}
    on_exit(fn -> Application.put_env(:tickmark, AI, cfg) end)
    :ok
  end

  test "설정과 프롬프트를 Messages API 형식으로 보내고 정상 응답을 파싱한다" do
    configure(model: "configured-triage-model", max_tokens: 4321, effort: "low")
    input = input()

    Req.Test.expect(Anthropic, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "api.anthropic.com"
      assert conn.request_path == "/v1/messages"
      assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2023-06-01"]
      assert Plug.Conn.get_req_header(conn, "x-api-key") == [AI.config()[:api_key]]
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      assert Plug.Conn.get_req_header(conn, "anthropic-beta") == []

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(body)
      assert body["model"] == "configured-triage-model"
      assert body["max_tokens"] == 4321
      assert body["system"] == Triage.system()
      assert [%{"role" => "user", "content" => message}] = body["messages"]
      assert Jason.decode!(message) == input
      assert body["output_config"]["effort"] == "low"
      assert body["output_config"]["format"]["type"] == "json_schema"

      assert body["output_config"]["format"]["schema"] ==
               Triage.output_schema() |> Jason.encode!() |> Jason.decode!()

      refute Map.has_key?(body, "thinking")
      refute Map.has_key?(body, "fallbacks")
      Req.Test.json(conn, message_response(valid_output()))
    end)

    assert {:ok, result} = Anthropic.triage(input, [])

    assert result == %{
             risk_level: :high,
             rationale: "approval_control_gap 룰이 승인자 공란을 탐지하여 증빙 대조가 필요합니다.",
             suggested_procedures: [
               %{procedure: "승인 이력을 증빙과 대조한다", evidence_to_obtain: "승인 이력과 전표 증빙"}
             ],
             missing_information: ["전표 증빙 원본"],
             response_model: "response-model-fixture",
             stop_reason: "end_turn",
             input_tokens: 123,
             output_tokens: 45
           }
  end

  test "text 블록만 이어서 읽고 thinking과 fallback 블록은 무시한다" do
    text = Jason.encode!(valid_output())
    {first, second} = String.split_at(text, div(String.length(text), 2))

    response =
      message_response(valid_output())
      |> Map.put("model", "fallback-model-fixture")
      |> Map.put("content", [
        %{"type" => "thinking", "thinking" => "모델 내부 추론"},
        %{"type" => "fallback", "text" => "JSON이 아닌 핸드오프 정보"},
        %{"type" => "text", "text" => first},
        %{"type" => "text", "text" => second}
      ])

    stub_response(response)
    assert {:ok, result} = Anthropic.triage(input())
    assert result.risk_level == :high
    assert result.response_model == "fallback-model-fixture"
  end

  test "fallback은 명시적으로 켠 경우에만 요청 본문과 beta 헤더에 들어간다" do
    configure(server_side_fallbacks: true)

    Req.Test.expect(Anthropic, fn conn ->
      assert Plug.Conn.get_req_header(conn, "anthropic-beta") ==
               ["server-side-fallback-2026-07-01"]

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["fallbacks"] == "default"
      Req.Test.json(conn, message_response(valid_output()))
    end)

    assert {:ok, _} = Anthropic.triage(input())
  end

  test "429의 retry-after 초를 파싱하고 없거나 잘못된 값이면 nil이다" do
    for {header, expected} <- [
          {"17", 17},
          {" 30 ", 30},
          {nil, nil},
          {"unknown", nil},
          {"3.5", nil},
          {"-1", nil},
          {"0", nil},
          {"17 seconds", nil}
        ] do
      Req.Test.expect(Anthropic, fn conn ->
        conn = if header, do: Plug.Conn.put_resp_header(conn, "retry-after", header), else: conn
        Plug.Conn.send_resp(conn, 429, "rate limited")
      end)

      assert Anthropic.triage(input()) == {:error, {:rate_limited, expected}}
    end
  end

  test "500, 529와 다른 5xx는 재시도 대상으로 분류하고 Req 자체 재시도는 없다" do
    configure(req_options: [plug: {Req.Test, Anthropic}, retry: :transient, max_retries: 3])

    for status <- [500, 529, 502, 503, 504] do
      Req.Test.expect(Anthropic, fn conn -> Plug.Conn.send_resp(conn, status, "unavailable") end)
      assert Anthropic.triage(input()) == {:error, {:retryable, {:http_status, status}}}
    end
  end

  test "400, 401, 404, 413과 권한 오류는 치명적 오류다" do
    for status <- [400, 401, 403, 404, 413] do
      Req.Test.expect(Anthropic, fn conn -> Plug.Conn.send_resp(conn, status, "invalid") end)
      assert Anthropic.triage(input()) == {:error, {:fatal, {:http_status, status}}}
    end
  end

  test "전송 실패와 타임아웃은 민감한 원본 오류 대신 안전한 재시도 분류를 반환한다" do
    for reason <- [:timeout, :closed, :econnrefused] do
      Req.Test.expect(Anthropic, &Req.Test.transport_error(&1, reason))
      assert Anthropic.triage(input()) == {:error, {:retryable, :transport_error}}
    end
  end

  test "stop_reason을 JSON 파싱보다 먼저 분류한다" do
    for {reason, error} <- [
          {"max_tokens", {:retryable, :max_tokens}},
          {"refusal", {:fatal, :refusal}},
          {"tool_use", {:fatal, :invalid_output}},
          {nil, {:fatal, :invalid_output}}
        ] do
      stub_response(%{"stop_reason" => reason, "content" => [%{"type" => "text", "text" => "{"}]})
      assert Anthropic.triage(input()) == {:error, error}
    end
  end

  test "필수 키, enum, 추가 키, 타입과 배열 개수 제한을 검증한다" do
    output = valid_output()
    procedure = hd(output["suggested_procedures"])

    invalid =
      Enum.map(Map.keys(output), &Map.delete(output, &1)) ++
        [
          nil,
          [],
          Map.put(output, "risk_level", "critical"),
          Map.put(output, "risk_level", "HIGH"),
          Map.put(output, "risk_level", nil),
          Map.put(output, "confidence", 0.99),
          Map.put(output, "rationale", nil),
          Map.put(output, "rationale", 123),
          Map.put(output, "rationale", "  "),
          Map.put(output, "suggested_procedures", nil),
          Map.put(output, "suggested_procedures", []),
          Map.put(output, "suggested_procedures", List.duplicate(procedure, 5)),
          Map.put(output, "suggested_procedures", ["절차"]),
          Map.put(output, "suggested_procedures", [Map.delete(procedure, "procedure")]),
          Map.put(output, "suggested_procedures", [Map.put(procedure, "extra", "추가 키")]),
          Map.put(output, "suggested_procedures", [Map.put(procedure, "evidence_to_obtain", nil)]),
          Map.put(output, "suggested_procedures", [Map.put(procedure, "procedure", "")]),
          Map.put(output, "missing_information", nil),
          Map.put(output, "missing_information", "증빙"),
          Map.put(output, "missing_information", List.duplicate("증빙", 6)),
          Map.put(output, "missing_information", [123]),
          Map.put(output, "missing_information", [""])
        ]

    for invalid_output <- invalid do
      stub_response(message_response(invalid_output))
      assert Anthropic.triage(input()) == {:error, {:fatal, :invalid_output}}
    end
  end

  test "최대 개수와 빈 missing_information은 유효하고 enum을 고정된 atom으로 바꾼다" do
    for {risk, atom} <- [{"low", :low}, {"medium", :medium}, {"high", :high}] do
      output =
        valid_output()
        |> Map.put("risk_level", risk)
        |> Map.put(
          "suggested_procedures",
          List.duplicate(hd(valid_output()["suggested_procedures"]), 4)
        )
        |> Map.put("missing_information", [])

      stub_response(message_response(output))
      assert {:ok, %{risk_level: ^atom, missing_information: []}} = Anthropic.triage(input())
    end

    output = Map.put(valid_output(), "missing_information", List.duplicate("증빙", 5))
    stub_response(message_response(output))
    assert {:ok, _} = Anthropic.triage(input())
  end

  test "모든 출력 필드에서 결론 단정, 승인 반려 의견과 부정 횡령 단정을 거부한다" do
    forbidden = [
      "이상 없음",
      "문제가 없습니다",
      "이상\n없음",
      "예외로 판단합니다",
      "승인을 권고합니다",
      "반려 의견입니다",
      "승인이 적절합니다",
      "반려해야 합니다",
      "승인할 것을 제안합니다",
      "반려되어야 합니다",
      "부정 거래로 판단합니다",
      "횡령이 확실합니다",
      "횡령임이 명백합니다",
      "담당자가 횡령을 저질렀습니다",
      "담당자가 횡령했습니다"
    ]

    for phrase <- forbidden,
        path <- [
          ["rationale"],
          ["suggested_procedures", Access.at(0), "procedure"],
          ["suggested_procedures", Access.at(0), "evidence_to_obtain"],
          ["missing_information", Access.at(0)]
        ] do
      output = put_in(valid_output(), path, phrase)
      stub_response(message_response(output))
      assert Anthropic.triage(input()) == {:error, {:fatal, :invalid_output}}
    end
  end

  test "모든 출력 필드에서 결론이 아닌 확인 질문과 감사절차 문장을 허용한다" do
    allowed = [
      "전표가 승인 대상 금액을 초과하는지 확인한다",
      "승인이 적절한 권한자에 의해 이루어졌는지 확인한다",
      "승인이 필요한 금액 기준을 확인한다",
      "거래에 문제가 없는지 증빙과 대조한다",
      "동일 금액 거래가 이상이 없는지 거래처 원장과 대조한다",
      "승인 가능 한도와 전표 금액을 비교한다",
      "입력자와 승인 권한자에게 입력 경위를 질문한다",
      "승인 이력, 결재 문서",
      "부정 위험 요인이 있는지 질문한다",
      "결재권자가 승인했는지 결재 이력을 확인한다",
      "기말 수기 전표의 승인 절차를 확인한다"
    ]

    for phrase <- allowed,
        path <- [
          ["rationale"],
          ["suggested_procedures", Access.at(0), "procedure"],
          ["suggested_procedures", Access.at(0), "evidence_to_obtain"],
          ["missing_information", Access.at(0)]
        ] do
      output = put_in(valid_output(), path, phrase)
      stub_response(message_response(output))
      result = Anthropic.triage(input())

      assert match?({:ok, _result}, result),
             "정상 감사절차 거절: #{phrase}, 필드: #{inspect(path)}"
    end
  end

  test "모든 출력 필드에서 단정하는 종결형과 가정하는 조건형을 구분한다" do
    cases = [
      {"거래에 문제가 없다", :reject},
      {"거래에 이상이 없으므로 추가 절차를 생략한다", :reject},
      {"승인이 필요합니다", :reject},
      {"반려가 타당하다", :reject},
      {"승인 권고", :reject},
      {"거래에 문제가 없다면 관련 증빙을 추가로 확보한다", :allow},
      {"승인이 필요하다면 권한자의 결재 이력을 확보한다", :allow},
      {"승인이 적절하다면 관련 승인 이력을 증빙과 대조한다", :allow}
    ]

    for {phrase, expected} <- cases,
        path <- [
          ["rationale"],
          ["suggested_procedures", Access.at(0), "procedure"],
          ["suggested_procedures", Access.at(0), "evidence_to_obtain"],
          ["missing_information", Access.at(0)]
        ] do
      output = put_in(valid_output(), path, phrase)
      stub_response(message_response(output))
      result = Anthropic.triage(input())

      case expected do
        :allow -> assert {:ok, _result} = result
        :reject -> assert result == {:error, {:fatal, :invalid_output}}
      end
    end
  end

  test "한국어 근거는 600자로 자르되 자르기 전 전체 텍스트의 금지 표현을 검사한다" do
    long_text = String.duplicate("가", 620)
    stub_response(message_response(Map.put(valid_output(), "rationale", long_text)))
    assert {:ok, result} = Anthropic.triage(input())
    assert result.rationale == String.duplicate("가", 600)

    output = Map.put(valid_output(), "rationale", long_text <> " 문제 없음")
    stub_response(message_response(output))
    assert Anthropic.triage(input()) == {:error, {:fatal, :invalid_output}}
  end

  test "잘못된 API 응답과 JSON은 원본을 반환하지 않고 거부한다" do
    response = message_response(valid_output())

    for malformed <- [
          Map.delete(response, "model"),
          Map.put(response, "model", nil),
          Map.delete(response, "usage"),
          put_in(response, ["usage", "input_tokens"], -1),
          put_in(response, ["usage", "output_tokens"], "45"),
          Map.put(response, "content", []),
          Map.put(response, "content", nil),
          Map.put(response, "content", [%{"type" => "text", "text" => "invalid JSON"}])
        ] do
      stub_response(malformed)
      assert Anthropic.triage(input()) == {:error, {:fatal, :invalid_output}}
    end

    Req.Test.expect(Anthropic, fn conn ->
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, "{")
    end)

    assert Anthropic.triage(input()) == {:error, {:fatal, :invalid_output}}
  end

  test "API 키가 응답이나 전송 오류에 반사되어도 오류 값과 로그에는 남지 않는다" do
    key = AI.config()[:api_key]

    log =
      capture_log(fn ->
        for status <- [400, 401, 429, 500, 529] do
          Req.Test.expect(Anthropic, fn conn -> Plug.Conn.send_resp(conn, status, key) end)
          assert {:error, error} = Anthropic.triage(input())
          refute inspect(error) =~ key
        end

        Req.Test.expect(Anthropic, fn conn ->
          Req.Test.transport_error(conn, {:tls_alert, {:handshake_failure, key}})
        end)

        assert {:error, {:retryable, :transport_error} = error} = Anthropic.triage(input())
        refute inspect(error) =~ key
      end)

    refute log =~ key
  end

  test "API 키가 없으면 HTTP 요청을 만들지 않고 안전하게 실패한다" do
    for key <- [nil, ""] do
      configure(api_key: key)
      assert Anthropic.triage(input()) == {:error, {:fatal, :missing_api_key}}
    end
  end

  defp configure(options) do
    Application.put_env(:tickmark, AI, Keyword.merge(AI.config(), options))
  end

  defp input do
    %{
      "engagement" => %{"performance_materiality" => "100000000", "fiscal_year" => 2025},
      "entry" => %{"entry_number" => "JE-001", "approved_by" => nil, "lines" => []},
      "rule_hits" => [%{"rule_id" => "approval_control_gap", "score" => 25}],
      "score" => 25,
      "context" => %{}
    }
  end

  defp valid_output do
    %{
      "risk_level" => "high",
      "rationale" => "approval_control_gap 룰이 승인자 공란을 탐지하여 증빙 대조가 필요합니다.",
      "suggested_procedures" => [
        %{"procedure" => "승인 이력을 증빙과 대조한다", "evidence_to_obtain" => "승인 이력과 전표 증빙"}
      ],
      "missing_information" => ["전표 증빙 원본"]
    }
  end

  defp message_response(output) do
    %{
      "model" => "response-model-fixture",
      "stop_reason" => "end_turn",
      "content" => [%{"type" => "text", "text" => Jason.encode!(output)}],
      "usage" => %{"input_tokens" => 123, "output_tokens" => 45}
    }
  end

  defp stub_response(response) do
    Req.Test.stub(Anthropic, &Req.Test.json(&1, response))
  end
end
