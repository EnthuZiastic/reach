defmodule Reach.Plugin do
  @moduledoc """
  Behaviour for library-specific analysis plugins.

  Plugins add edges to the dependence graph that capture domain-specific
  dependencies invisible to the language-level analysis — framework dispatch,
  message routing, pipeline topology, etc.

  ## Implementing a plugin

      defmodule MyPlugin do
        @behaviour Reach.Plugin

        @impl true
        def analyze(all_nodes, _opts) do
          # Return edge tuples: {from_node_id, to_node_id, label}
          []
        end
      end

  ## Using plugins

  Plugins for Phoenix, Ecto, Oban, and GenStage are included and
  auto-detected at runtime. Override with the `:plugins` option:

      Reach.string_to_graph!(source, plugins: [Reach.Plugins.Phoenix])
      Reach.Project.from_mix_project(plugins: [Reach.Plugins.Ecto])

  Disable auto-detection:

      Reach.string_to_graph!(source, plugins: [])
  """

  alias Reach.IR.Node

  @type edge_spec :: {Node.id(), Node.id(), term()}

  @doc """
  Analyzes IR nodes from a single module and returns edges to add.
  """
  @callback analyze(all_nodes :: [Node.t()], opts :: keyword()) :: [edge_spec()]

  @doc """
  Analyzes IR nodes across all modules in a project.

  Optional — only needed for cross-module patterns like router→controller
  dispatch or job enqueue→perform flow.
  """
  @callback analyze_project(
              modules :: %{module() => map()},
              all_nodes :: [Node.t()],
              opts :: keyword()
            ) :: [edge_spec()]

  @optional_callbacks [analyze_project: 3]

  @known_plugins [
    {Phoenix.Router, Reach.Plugins.Phoenix},
    {Ecto, Reach.Plugins.Ecto},
    {Oban, Reach.Plugins.Oban},
    {GenStage, Reach.Plugins.GenStage}
  ]

  @doc false
  def detect do
    for {mod, plugin} <- @known_plugins,
        Code.ensure_loaded?(mod) do
      plugin
    end
  end

  @doc false
  def resolve(opts) do
    case Keyword.get(opts, :plugins) do
      nil -> detect()
      [] -> []
      list when is_list(list) -> list
    end
  end

  @doc false
  def run_analyze(plugins, all_nodes, opts) do
    Enum.flat_map(plugins, fn plugin ->
      plugin.analyze(all_nodes, opts)
    end)
  end

  @doc false
  def run_analyze_project(plugins, modules, all_nodes, opts) do
    Enum.flat_map(plugins, fn plugin ->
      if function_exported?(plugin, :analyze_project, 3) do
        plugin.analyze_project(modules, all_nodes, opts)
      else
        []
      end
    end)
  end
end
