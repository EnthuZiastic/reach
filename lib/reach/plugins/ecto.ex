defmodule Reach.Plugins.Ecto do
  @moduledoc false
  @behaviour Reach.Plugin

  alias Reach.IR

  @repo_write_fns [
    :insert,
    :insert!,
    :update,
    :update!,
    :delete,
    :delete!,
    :insert_or_update,
    :insert_or_update!,
    :insert_all,
    :insert_all!
  ]

  @impl true
  def analyze(all_nodes, _opts) do
    changeset_to_repo_edges(all_nodes) ++
      raw_query_edges(all_nodes) ++
      cast_field_edges(all_nodes)
  end

  # Changeset → Repo.insert: trace data from cast params to write
  defp changeset_to_repo_edges(all_nodes) do
    cast_calls = find_calls(all_nodes, nil, :cast) ++ find_calls(all_nodes, Ecto.Changeset, :cast)

    repo_writes =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and to_string(n.meta[:module] || "") =~ "Repo" and
          n.meta[:function] in @repo_write_fns
      end)

    for cast <- cast_calls,
        write <- repo_writes do
      {cast.id, write.id, {:ecto_changeset_flow, cast.meta[:function]}}
    end
  end

  # Raw SQL: Repo.query("SELECT ...") or Ecto.Adapters.SQL.query
  defp raw_query_edges(all_nodes) do
    raw_calls =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and
          (n.meta[:function] in [:query, :query!] and
             (to_string(n.meta[:module] || "") =~ "Repo" or
                n.meta[:module] == Ecto.Adapters.SQL))
      end)

    for call <- raw_calls,
        arg <- call.children,
        var_node <- find_vars_in(arg) do
      {var_node.id, call.id, :ecto_raw_query}
    end
  end

  # cast(changeset, params, [:field1, :field2]) — track which fields are cast
  defp cast_field_edges(all_nodes) do
    cast_calls = find_calls(all_nodes, nil, :cast) ++ find_calls(all_nodes, Ecto.Changeset, :cast)
    Enum.flat_map(cast_calls, &cast_param_edges/1)
  end

  defp cast_param_edges(%{children: [_changeset, params | _]} = call) do
    for var <- find_vars_in(params), do: {var.id, call.id, :ecto_cast_params}
  end

  defp cast_param_edges(_), do: []

  defp find_calls(all_nodes, module, function) do
    Enum.filter(all_nodes, fn n ->
      n.type == :call and n.meta[:function] == function and
        (module == nil or n.meta[:module] == module)
    end)
  end

  defp find_vars_in(node) do
    node |> IR.all_nodes() |> Enum.filter(&(&1.type == :var))
  end
end
