defmodule Tickmark.Testing.Rules do
  @moduledoc """
  The rule registry. An explicit list in domain doc 2.1 order, so the screens
  show the rules in that order. No macros, no runtime discovery: adding a rule
  means adding one line here.
  """

  @rules [
    {"approval_control_gap", Tickmark.Testing.Rules.ApprovalControlGap}
  ]

  # Test-only rules from config/test.exs (empty elsewhere). fetch/1 finds them
  # so tests can exercise skip and failure paths, but all/0 and ids/0 never
  # list them, so a run over :all uses real rules only.
  @extra_rules Application.compile_env(:tickmark, [__MODULE__, :extra_rules], [])

  @doc "Rule modules in registry order."
  @spec all() :: [module()]
  def all, do: Enum.map(@rules, fn {_id, module} -> module end)

  @doc "Rule ids in registry order."
  @spec ids() :: [String.t()]
  def ids, do: Enum.map(@rules, fn {id, _module} -> id end)

  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(rule_id) do
    case List.keyfind(@rules ++ @extra_rules, rule_id, 0) do
      {^rule_id, module} -> {:ok, module}
      nil -> :error
    end
  end
end
