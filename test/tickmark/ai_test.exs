defmodule Tickmark.AITest do
  use ExUnit.Case, async: true

  alias Tickmark.AI

  test "기본 구현은 Fake이며 진입점이 같은 결과를 반환한다" do
    input = %{"rule_hits" => [%{"rule_id" => "approval_control_gap"}], "score" => 25}

    assert AI.client() == AI.Fake
    assert AI.config()[:client] == AI.Fake
    assert AI.triage(input) == AI.Fake.triage(input, [])
  end

  describe "input_hash/1" do
    test "정렬된 JSON의 SHA-256을 소문자 64자 hex로 반환한다" do
      expected = :crypto.hash(:sha256, ~s({"a":1,"b":2})) |> Base.encode16(case: :lower)

      assert AI.input_hash(%{b: 2, a: 1}) == expected
      assert AI.input_hash(%{"a" => 1, "b" => 2}) == expected
      assert AI.input_hash(%{a: 1, b: 2}) =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "중첩 맵과 배열 안의 맵도 키 순서와 무관하다" do
      atom_keys = %{z: [%{b: 2, a: %{d: 4, c: 3}}], a: nil}
      string_keys = %{"a" => nil, "z" => [%{"a" => %{"c" => 3, "d" => 4}, "b" => 2}]}

      assert AI.input_hash(atom_keys) == AI.input_hash(string_keys)
      assert AI.input_hash(atom_keys) == AI.input_hash(atom_keys)
    end

    test "32개를 넘는 맵도 JSON 키의 사전 순서대로 해시한다" do
      input = Map.new(1..40, fn i -> {"key_#{i}", i} end)
      keys = Enum.map_join(1..40, ",", fn i -> ~s("key_#{i}":#{i}) end)

      # Numeric insertion order is different from the canonical lexical order.
      sorted_keys = keys |> String.split(",") |> Enum.sort() |> Enum.join(",")
      json = "{\"nested\":{" <> sorted_keys <> "}}"
      expected = :crypto.hash(:sha256, json) |> Base.encode16(case: :lower)

      assert AI.input_hash(%{nested: input}) == expected
    end

    test "Decimal과 날짜는 각자의 JSON 인코더를 유지한다" do
      input = %{amount: Decimal.new("123.00"), date: ~D[2025-12-31]}

      assert AI.input_hash(input) ==
               AI.input_hash(%{"date" => "2025-12-31", "amount" => "123.00"})
    end

    test "값이나 배열 순서가 달라지면 다른 해시다" do
      refute AI.input_hash(%{score: 25}) == AI.input_hash(%{score: 26})
      refute AI.input_hash(%{lines: [1, 2]}) == AI.input_hash(%{lines: [2, 1]})
    end
  end
end
