defmodule Tickmark.TestRules.Skip do
  @moduledoc "Test-only rule (config/test.exs) that always skips."
  @behaviour Tickmark.Testing.Rule

  @impl true
  def id, do: "test_skip"
  @impl true
  def name, do: "테스트용 건너뜀"
  @impl true
  def description, do: "항상 실행 조건 미달을 돌려준다"
  @impl true
  def weight, do: 10
  @impl true
  def default_params, do: %{}
  @impl true
  def run(_context), do: {:skip, "테스트용 건너뜀"}
end

defmodule Tickmark.TestRules.Error do
  @moduledoc "Test-only rule (config/test.exs) that always returns an error."
  @behaviour Tickmark.Testing.Rule

  @impl true
  def id, do: "test_error"
  @impl true
  def name, do: "테스트용 오류"
  @impl true
  def description, do: "항상 오류를 돌려준다"
  @impl true
  def weight, do: 10
  @impl true
  def default_params, do: %{}
  @impl true
  def run(_context), do: {:error, :test_error}
end

defmodule Tickmark.TestRules.Raise do
  @moduledoc "Test-only rule (config/test.exs) that always raises."
  @behaviour Tickmark.Testing.Rule

  @impl true
  def id, do: "test_raise"
  @impl true
  def name, do: "테스트용 예외"
  @impl true
  def description, do: "항상 예외를 던진다"
  @impl true
  def weight, do: 10
  @impl true
  def default_params, do: %{}
  @impl true
  def run(_context), do: raise("test_raise rule")
end
