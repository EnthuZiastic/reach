defmodule ExPDG.IR.Counter do
  @moduledoc false

  use Agent

  def start_link(initial \\ 0) do
    Agent.start_link(fn -> initial end)
  end

  def next(counter) do
    Agent.get_and_update(counter, fn n -> {n, n + 1} end)
  end

  def stop(counter) do
    Agent.stop(counter)
  end
end
