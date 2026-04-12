defmodule ExPDG.PDG do
  @moduledoc """
  Program Dependence Graph.

  Merges CDG (control dependence) and DDG (data dependence) into a single graph.
  Provides slicing and independence queries.
  """

  alias ExPDG.{IR, CFG, CDG, DDG}
  alias ExPDG.IR.Node

  @type t :: %__MODULE__{
          graph: Graph.t(),
          ir: [Node.t()],
          cfg: Graph.t(),
          nodes: %{Node.id() => Node.t()}
        }

  @enforce_keys [:graph, :ir, :cfg, :nodes]
  defstruct [:graph, :ir, :cfg, :nodes]

  @doc """
  Builds a PDG from Elixir source code containing a function definition.
  """
  @spec from_string(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_string(source, opts \\ []) do
    case IR.from_string(source, opts) do
      {:ok, nodes} ->
        {:ok, build(nodes)}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Builds a PDG from IR nodes.

  Expects the nodes to contain at least one function definition.
  """
  @spec build([Node.t()]) :: t()
  def build(ir_nodes) do
    func_defs = IR.find_by_type(ir_nodes, :function_def)

    all_nodes = IR.all_nodes(ir_nodes)
    node_map = Map.new(all_nodes, fn n -> {n.id, n} end)

    # Build CFG from first function def (or build a simple one for expressions)
    {cfg, cdg, ddg} =
      case func_defs do
        [func_def | _] ->
          cfg = CFG.build(func_def)
          cdg = CDG.build(cfg)
          ddg = DDG.build(func_def)
          {cfg, cdg, ddg}

        [] ->
          # No function def — build DDG only for expressions
          cfg = Graph.new()
          cdg = Graph.new()
          ddg = DDG.build(ir_nodes)
          {cfg, cdg, ddg}
      end

    # Merge CDG + DDG
    graph = merge_graphs(cdg, ddg)

    %__MODULE__{
      graph: graph,
      ir: ir_nodes,
      cfg: cfg,
      nodes: node_map
    }
  end

  @doc """
  Backward slice: all nodes that affect the given node.
  """
  @spec backward_slice(t(), Node.id()) :: [Node.id()]
  def backward_slice(%__MODULE__{graph: graph}, node_id) do
    if Graph.has_vertex?(graph, node_id) do
      Graph.reaching(graph, [node_id])
      |> Enum.reject(&(&1 == node_id))
    else
      []
    end
  end

  @doc """
  Forward slice: all nodes affected by the given node.
  """
  @spec forward_slice(t(), Node.id()) :: [Node.id()]
  def forward_slice(%__MODULE__{graph: graph}, node_id) do
    if Graph.has_vertex?(graph, node_id) do
      Graph.reachable(graph, [node_id])
      |> Enum.reject(&(&1 == node_id))
    else
      []
    end
  end

  @doc """
  Chop: nodes on paths from `source` to `sink`.

  Returns the intersection of the forward slice of `source`
  and the backward slice of `sink`.
  """
  @spec chop(t(), Node.id(), Node.id()) :: [Node.id()]
  def chop(pdg, source, sink) do
    fwd = forward_slice(pdg, source) |> MapSet.new()
    bwd = backward_slice(pdg, sink) |> MapSet.new()
    MapSet.intersection(fwd, bwd) |> MapSet.to_list()
  end

  @doc """
  Returns the control dependencies of a node.
  """
  @spec control_deps(t(), Node.id()) :: [{Node.id(), term()}]
  def control_deps(%__MODULE__{graph: graph}, node_id) do
    Graph.edges(graph)
    |> Enum.filter(fn e ->
      e.v2 == node_id and match?({:control, _}, e.label)
    end)
    |> Enum.map(fn e -> {e.v1, e.label} end)
  end

  @doc """
  Returns the data dependencies of a node (nodes it depends on).
  """
  @spec data_deps(t(), Node.id()) :: [{Node.id(), atom()}]
  def data_deps(%__MODULE__{graph: graph}, node_id) do
    Graph.edges(graph)
    |> Enum.filter(fn e ->
      e.v2 == node_id and match?({:data, _}, e.label)
    end)
    |> Enum.map(fn e ->
      {:data, var} = e.label
      {e.v1, var}
    end)
  end

  @doc """
  Checks if two nodes are independent.

  Two nodes are independent if:
  1. No data-dependence path between them
  2. They have the same control dependencies
  """
  @spec independent?(t(), Node.id(), Node.id()) :: boolean()
  def independent?(%__MODULE__{graph: graph} = pdg, id_x, id_y) do
    not data_reachable?(graph, id_x, id_y) and
      not data_reachable?(graph, id_y, id_x) and
      same_control_deps?(pdg, id_x, id_y)
  end

  @doc """
  Returns the IR node for a given ID.
  """
  @spec node(t(), Node.id()) :: Node.t() | nil
  def node(%__MODULE__{nodes: nodes}, id) do
    Map.get(nodes, id)
  end

  @doc """
  Returns all edges in the PDG.
  """
  @spec edges(t()) :: [Graph.Edge.t()]
  def edges(%__MODULE__{graph: graph}) do
    Graph.edges(graph)
  end

  @doc """
  Exports the PDG to DOT format.
  """
  @spec to_dot(t()) :: {:ok, String.t()} | {:error, term()}
  def to_dot(%__MODULE__{graph: graph}) do
    Graph.to_dot(graph)
  end

  # --- Private ---

  defp merge_graphs(cdg, ddg) do
    # Start with CDG vertices and edges
    graph =
      Graph.vertices(cdg)
      |> Enum.reduce(Graph.new(), &Graph.add_vertex(&2, &1))

    graph =
      Graph.edges(cdg)
      |> Enum.reduce(graph, fn e, g ->
        Graph.add_edge(g, e.v1, e.v2, label: e.label)
      end)

    # Add DDG vertices and edges
    graph =
      Graph.vertices(ddg)
      |> Enum.reduce(graph, &Graph.add_vertex(&2, &1))

    Graph.edges(ddg)
    |> Enum.reduce(graph, fn e, g ->
      Graph.add_edge(g, e.v1, e.v2, label: e.label)
    end)
  end

  defp data_reachable?(graph, from, to) do
    # Check if there's a path using only data edges
    data_graph = filter_data_edges(graph)

    if Graph.has_vertex?(data_graph, from) and Graph.has_vertex?(data_graph, to) do
      Graph.get_shortest_path(data_graph, from, to) != nil
    else
      false
    end
  end

  defp filter_data_edges(graph) do
    Enum.reduce(Graph.edges(graph), Graph.new(), fn edge, g ->
      case edge.label do
        {:data, _} ->
          g
          |> Graph.add_vertex(edge.v1)
          |> Graph.add_vertex(edge.v2)
          |> Graph.add_edge(edge.v1, edge.v2, label: edge.label)

        _ ->
          g
      end
    end)
  end

  defp same_control_deps?(pdg, id_x, id_y) do
    deps_x = control_deps(pdg, id_x) |> MapSet.new()
    deps_y = control_deps(pdg, id_y) |> MapSet.new()
    MapSet.equal?(deps_x, deps_y)
  end
end
