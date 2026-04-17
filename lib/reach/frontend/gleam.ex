defmodule Reach.Frontend.Gleam do
  @moduledoc """
  Gleam frontend — parses Gleam source via its generated Erlang output.

  Gleam compiles `.gleam` files to `.erl` with `-file` directives that
  preserve the original source line numbers. This frontend locates the
  generated Erlang, parses it with the Erlang frontend, and remaps
  `source_span.file` to the original `.gleam` path so the visualizer
  shows Gleam source code.

  Requires the Gleam project to be built first (`gleam build`).
  """

  alias Reach.Frontend.Erlang, as: ErlangFrontend
  alias Reach.IR.Node

  @spec parse_file(Path.t(), keyword()) :: {:ok, [Node.t()]} | {:error, term()}
  def parse_file(gleam_path, opts \\ []) do
    gleam_path = Path.expand(gleam_path)

    with {:ok, erl_path} <- find_generated_erlang(gleam_path),
         {:ok, func_info} <- extract_func_info(erl_path, gleam_path),
         {:ok, nodes} <- ErlangFrontend.parse_file(erl_path, opts) do
      populate_def_cache(gleam_path, func_info.ranges)
      {:ok, remap_nodes(nodes, gleam_path, func_info)}
    end
  end

  def find_generated_erlang(gleam_path) do
    case find_project_root(gleam_path) do
      nil ->
        {:error, {:gleam_project_not_found, gleam_path}}

      root ->
        relative = Path.relative_to(gleam_path, Path.join(root, "src"))
        module_name = relative |> Path.rootname() |> String.replace("/", "@")

        pattern =
          Path.join([
            root,
            "build",
            "*",
            "erlang",
            "*",
            "_gleam_artefacts",
            module_name <> ".erl"
          ])

        case Path.wildcard(pattern) do
          [erl | _] -> {:ok, erl}
          [] -> {:error, {:gleam_not_built, gleam_path, "run `gleam build` first"}}
        end
    end
  end

  defp find_project_root(path) do
    dir = if File.dir?(path), do: path, else: Path.dirname(path)
    walk_up(dir)
  end

  defp walk_up("/"), do: nil

  defp walk_up(dir) do
    if File.exists?(Path.join(dir, "gleam.toml")) do
      dir
    else
      parent = Path.dirname(dir)
      if parent == dir, do: nil, else: walk_up(parent)
    end
  end

  defp extract_func_info(erl_path, gleam_path) do
    case :epp.parse_file(to_charlist(erl_path), []) do
      {:ok, forms} ->
        gleam_lines =
          case File.read(gleam_path) do
            {:ok, src} -> String.split(src, "\n")
            _ -> []
          end

        line_count = length(gleam_lines)

        # Collect -file directive offsets and function body start lines
        {file_offsets, body_starts} =
          Enum.reduce(forms, {[], %{}}, fn form, {offsets, body_map} ->
            case form do
              {:attribute, _, :file, {file, line}} ->
                if to_string(file) |> String.ends_with?(".gleam") do
                  {[line | offsets], Map.put(body_map, :_pending, line)}
                else
                  {offsets, body_map}
                end

              {:function, fn_line, _name, _arity, _clauses} ->
                case Map.pop(body_map, :_pending) do
                  {nil, body_map} ->
                    {offsets, body_map}

                  {directive_line, body_map} ->
                    {offsets, Map.put(body_map, fn_line, directive_line)}
                end

              _ ->
                {offsets, body_map}
            end
          end)

        file_offsets = file_offsets |> Enum.sort()

        ranges =
          file_offsets
          |> Enum.with_index()
          |> Enum.map(fn {start, idx} ->
            next = Enum.at(file_offsets, idx + 1)
            raw_end = if next, do: next - 1, else: line_count
            end_line = trim_trailing_blanks(gleam_lines, start, raw_end)
            {start, end_line}
          end)

        {:ok, %{ranges: ranges, body_to_head: body_starts, line_count: line_count}}

      {:error, _} = err ->
        err
    end
  end

  defp populate_def_cache(gleam_path, func_ranges) do
    line_map = Map.new(func_ranges)
    cache = Process.get(:reach_def_end_cache, %{})
    Process.put(:reach_def_end_cache, Map.put(cache, gleam_path, line_map))
  end

  defp remap_nodes(nodes, gleam_path, func_info) when is_list(nodes) do
    Enum.map(nodes, fn node ->
      {head_line, max_line} = func_bounds(node, func_info)
      remap_node(node, gleam_path, head_line, max_line)
    end)
  end

  defp func_bounds(%Node{type: :function_def, source_span: %{start_line: body_start}}, info) do
    head_line = Map.get(info.body_to_head, body_start)

    max_line =
      case Enum.find(info.ranges, fn {s, _} -> s <= body_start and body_start <= s + 5 end) do
        {_, end_line} -> end_line
        nil -> nil
      end

    {head_line, max_line}
  end

  defp func_bounds(_, _), do: {nil, nil}

  defp remap_node(%Node{type: :function_def} = node, gleam_path, head_line, max_line) do
    span = remap_span(node.source_span, gleam_path, max_line)
    span = if head_line, do: %{span | start_line: head_line}, else: span

    %{
      node
      | source_span: span,
        children: Enum.map(node.children || [], &remap_child(&1, gleam_path, max_line))
    }
  end

  defp remap_node(%Node{} = node, gleam_path, _, max_line) do
    remap_child(node, gleam_path, max_line)
  end

  defp remap_child(%Node{children: children, source_span: span} = node, gleam_path, max_line) do
    %{
      node
      | source_span: remap_span(span, gleam_path, max_line),
        children: Enum.map(children || [], &remap_child(&1, gleam_path, max_line))
    }
  end

  defp remap_span(nil, _, _), do: nil

  defp remap_span(span, gleam_path, max_line) do
    %{
      span
      | file: gleam_path,
        start_line: clamp(span[:start_line], max_line),
        end_line: clamp(span[:end_line], max_line)
    }
  end

  defp clamp(nil, _), do: nil
  defp clamp(line, nil), do: line
  defp clamp(line, max), do: min(line, max)

  defp trim_trailing_blanks(lines, start, end_line) do
    end_line..start//-1
    |> Enum.find(fn l ->
      line = Enum.at(lines, l - 1, "")
      String.trim(line) != ""
    end)
    |> Kernel.||(start)
  end
end
