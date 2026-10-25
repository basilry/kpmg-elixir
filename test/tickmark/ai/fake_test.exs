defmodule Tickmark.AI.FakeTest do
  use ExUnit.Case, async: true

  alias Tickmark.AI
  alias Tickmark.AI.Fake

  test "같은 입력은 같은 제안과 버전이 있는 모델 ID를 반환한다" do
    input = %{
      "rule_hits" => [
        %{"rule_id" => "period_end_manual", "score" => 20},
        %{"rule_id" => "approval_control_gap", "score" => 25}
      ],
      "score" => 45
    }

    assert {:ok, result} = Fake.triage(input, [])
    assert Fake.triage(input, []) == {:ok, result}
    assert result.response_model == "fake-triage-v1"
    assert result.stop_reason == "end_turn"
    assert result.input_tokens == 0
    assert result.output_tokens == 0
    assert result.rationale =~ "approval_control_gap"
    assert result.rationale =~ "period_end_manual"

    <<byte, _::binary>> = input |> AI.input_hash() |> Base.decode16!(case: :lower)
    assert result.risk_level == Enum.at([:low, :medium, :high], rem(byte, 3))
  end

  test "위험도 세 값이 나오며 모든 출력이 도메인 스키마를 지킨다" do
    results =
      for score <- 0..100 do
        assert {:ok, result} = Fake.triage(%{score: score, rule_hits: []})
        assert String.length(result.rationale) in 1..600
        assert length(result.suggested_procedures) in 1..4
        assert length(result.missing_information) <= 5
        assert Enum.all?(result.missing_information, &is_binary/1)

        for item <- result.suggested_procedures do
          assert Enum.sort(Map.keys(item)) == [:evidence_to_obtain, :procedure]
          assert is_binary(item.procedure) and item.procedure != ""
          assert is_binary(item.evidence_to_obtain) and item.evidence_to_obtain != ""
        end

        assert Enum.sort(Map.keys(result)) ==
                 Enum.sort([
                   :risk_level,
                   :rationale,
                   :suggested_procedures,
                   :missing_information,
                   :response_model,
                   :stop_reason,
                   :input_tokens,
                   :output_tokens
                 ])

        result
      end

    assert results |> Enum.map(& &1.risk_level) |> Enum.uniq() |> Enum.sort() ==
             [:high, :low, :medium]
  end

  test "맵의 키 표현이 달라도 출력은 같고 입력은 변경하지 않는다" do
    atoms = %{rule_hits: [%{rule_id: "approval_control_gap"}], score: 25}
    strings = %{"score" => 25, "rule_hits" => [%{"rule_id" => "approval_control_gap"}]}

    assert Fake.triage(atoms) == Fake.triage(strings)
    assert atoms.score == 25
    assert atoms.rule_hits == [%{rule_id: "approval_control_gap"}]
  end
end
