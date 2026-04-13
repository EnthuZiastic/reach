defmodule Reach.Plugins.Phoenix do
  @moduledoc false
  @behaviour Reach.Plugin

  alias Reach.IR

  @impl true
  def analyze(all_nodes, _opts) do
    conn_param_to_action_edges(all_nodes) ++
      action_fallback_edges(all_nodes) ++
      socket_assign_edges(all_nodes)
  end

  @impl true
  def analyze_project(_modules, all_nodes, _opts) do
    plug_chain_edges(all_nodes)
  end

  # conn.params / fetch_query_params → action body (taint source)
  defp conn_param_to_action_edges(all_nodes) do
    param_accesses =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and
          n.meta[:function] in [:params, :query_params, :body_params, :path_params] and
          (n.meta[:module] in [Plug.Conn, nil] or to_string(n.meta[:module] || "") =~ "Conn")
      end)

    for access <- param_accesses do
      {access.id, access.id, :phoenix_params}
    end
  end

  # action_fallback — error returns flow to fallback controller
  defp action_fallback_edges(all_nodes) do
    fallbacks =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and n.meta[:function] == :action_fallback
      end)

    error_tuples =
      Enum.filter(all_nodes, fn n ->
        n.type == :tuple and
          match?([%{type: :literal, meta: %{value: :error}} | _], n.children)
      end)

    for fb <- fallbacks,
        err <- error_tuples do
      {err.id, fb.id, :phoenix_action_fallback}
    end
  end

  # socket assigns: assign(socket, :key, val) → @key in template
  defp socket_assign_edges(all_nodes) do
    assigns =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and n.meta[:function] == :assign and
          n.meta[:kind] == :local
      end)

    for assign_call <- assigns,
        arg <- assign_call.children,
        var <- find_vars_in(arg) do
      {var.id, assign_call.id, :phoenix_assign}
    end
  end

  # Plug chains: pipe_through [:auth, :browser] → control deps
  defp plug_chain_edges(all_nodes) do
    pipe_throughs =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and n.meta[:function] == :pipe_through
      end)

    actions =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and n.meta[:function] in [:get, :post, :put, :patch, :delete, :resources]
      end)

    for pt <- pipe_throughs,
        action <- actions do
      {pt.id, action.id, :phoenix_plug_chain}
    end
  end

  defp find_vars_in(node) do
    node |> IR.all_nodes() |> Enum.filter(&(&1.type == :var))
  end
end
