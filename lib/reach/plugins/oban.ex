defmodule Reach.Plugins.Oban do
  @moduledoc false
  @behaviour Reach.Plugin

  alias Reach.IR

  @impl true
  def analyze(all_nodes, _opts) do
    job_args_edges(all_nodes)
  end

  @impl true
  def analyze_project(_modules, all_nodes, _opts) do
    enqueue_to_perform_edges(all_nodes)
  end

  # Within a worker: %Oban.Job{args: args} → args used in body
  defp job_args_edges(all_nodes) do
    perform_fns =
      Enum.filter(all_nodes, fn n ->
        n.type == :function_def and n.meta[:name] == :perform
      end)

    Enum.flat_map(perform_fns, fn func_def ->
      func_nodes = IR.all_nodes(func_def)

      args_vars =
        Enum.filter(func_nodes, fn n ->
          n.type == :var and n.meta[:name] in [:args, :job]
        end)

      calls = Enum.filter(func_nodes, &(&1.type == :call))

      for var <- args_vars,
          call <- calls do
        {var.id, call.id, :oban_job_args}
      end
    end)
  end

  # Cross-module: Oban.insert(Worker.new(%{key: val})) → Worker.perform
  defp enqueue_to_perform_edges(all_nodes) do
    inserts =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and
          (n.meta[:module] == Oban and n.meta[:function] in [:insert, :insert!])
      end)

    performs =
      Enum.filter(all_nodes, fn n ->
        n.type == :function_def and n.meta[:name] == :perform
      end)

    for insert <- inserts,
        perform <- performs,
        arg <- insert.children,
        var <- find_vars_in(arg) do
      {var.id, perform.id, :oban_enqueue}
    end
  end

  defp find_vars_in(node) do
    node |> IR.all_nodes() |> Enum.filter(&(&1.type == :var))
  end
end
