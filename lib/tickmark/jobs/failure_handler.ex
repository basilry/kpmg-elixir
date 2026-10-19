defmodule Tickmark.Jobs.FailureHandler do
  @moduledoc """
  Records the final failure of a job that raised or timed out (design doc 5.4).

  Skeleton from the main session so `Tickmark.Application` can call
  `attach/0`. Worker A replaces this module in round 3 (WBS 2.1).
  """

  @spec attach() :: :ok
  def attach, do: :ok
end
