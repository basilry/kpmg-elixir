defmodule Tickmark.AI.Fake do
  @moduledoc """
  Deterministic demo suggestions. No network, API key, or audit decision.
  """
  @behaviour Tickmark.AI.Client

  @impl true
  def triage(input, _opts \\ []) do
    <<first_byte, _rest::binary>> =
      input |> Tickmark.AI.input_hash() |> Base.decode16!(case: :lower)

    rule_ids =
      input
      |> Map.get(:rule_hits, Map.get(input, "rule_hits", []))
      |> Enum.map(fn hit -> Map.get(hit, :rule_id, Map.get(hit, "rule_id")) end)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.join(", ")

    rationale =
      case rule_ids do
        "" -> "제공된 전표의 입력 사실과 증빙을 대조하는 추가 검토가 필요합니다."
        ids -> "적중 룰 #{ids}의 근거를 관련 증빙과 대조하는 추가 검토가 필요합니다."
      end

    {:ok,
     %{
       risk_level: Enum.at([:low, :medium, :high], rem(first_byte, 3)),
       rationale: String.slice(rationale, 0, 600),
       suggested_procedures: [
         %{
           procedure: "적중 룰의 근거와 전표 입력 경위를 증빙에 대조한다",
           evidence_to_obtain: "전표 증빙 원본과 승인 이력"
         }
       ],
       missing_information: ["전표를 뒷받침하는 증빙 원본"],
       response_model: "fake-triage-v1",
       stop_reason: "end_turn",
       input_tokens: 0,
       output_tokens: 0
     }}
  end
end
