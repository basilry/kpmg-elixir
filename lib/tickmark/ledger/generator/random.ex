defmodule Tickmark.Ledger.Generator.Random do
  @moduledoc """
  시드 고정 난수. 상태를 프로세스 사전에 두지 않고 함수 인자로 넘기고 돌려받는다.

  모든 함수는 `{값, 새 상태}` 를 돌려준다. 같은 시드에서 같은 순서로 부르면 항상 같은 값이 나온다.
  알고리즘은 `:exsss` 로 고정한다. OTP 기본 알고리즘이 바뀌어도 결과가 바뀌지 않게 하기 위해서다.
  """

  @algorithm :exsss

  @type t :: :rand.state()

  @spec new(integer()) :: t()
  def new(seed) when is_integer(seed), do: :rand.seed_s(@algorithm, seed)

  @doc "min 이상 max 이하 정수."
  @spec integer(integer(), integer(), t()) :: {integer(), t()}
  def integer(min, max, state) when min <= max do
    {n, state} = :rand.uniform_s(max - min + 1, state)
    {min + n - 1, state}
  end

  @doc "튜플에서 하나를 고른다. 튜플은 인덱스 접근이 O(1) 이다."
  @spec pick(tuple(), t()) :: {term(), t()}
  def pick(tuple, state) when tuple_size(tuple) > 0 do
    {i, state} = integer(0, tuple_size(tuple) - 1, state)
    {elem(tuple, i), state}
  end

  @doc """
  목록을 섞는다. 원소마다 난수 키를 붙여 정렬하고, 키가 같으면 원래 위치로 순서를 정한다.
  `Enum.shuffle/1` 은 전역 난수 상태를 쓰므로 쓰지 않는다.
  """
  @spec shuffle(list(), t()) :: {list(), t()}
  def shuffle(list, state) do
    {keyed, state} =
      list
      |> Enum.with_index()
      |> Enum.map_reduce(state, fn {item, index}, state ->
        {key, state} = :rand.uniform_s(state)
        {{key, index, item}, state}
      end)

    sorted =
      keyed
      |> Enum.sort_by(fn {key, index, _item} -> {key, index} end)
      |> Enum.map(fn {_key, _index, item} -> item end)

    {sorted, state}
  end
end
