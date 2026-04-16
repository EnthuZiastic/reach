defmodule Reach.Visualize.ControlFlow do
  @moduledoc false

  alias Reach.{IR, Visualize}

  @doc """
  Builds expression-oriented control flow visualization data.

  Source is the primary data — every line of every function is visible.
  Branch/merge/data-flow edges are computed from the AST structure
  (when source file is available) or from the IR tree (as fallback).
  """
  def build(all_nodes, graph) do
    modules =
      all_nodes
      |> Enum.filter(&(&1.type == :module_def))
      |> Enum.map(&build_module(&1, all_nodes, graph))

    top_funcs = find_top_level_functions(all_nodes, modules)

    if top_funcs != [] do
      file = top_funcs |> Enum.find_value(&span_field(&1, :file))
      top = build_module_from_funcs(top_funcs, file, graph)
      [top | modules]
    else
      modules
    end
  end

  # ── Module-level ──

  defp build_module(mod, _all_nodes, graph) do
    file = span_field(mod, :file)
    Visualize.ensure_def_cache(file)

    ir_nodes = IR.all_nodes(mod)

    func_defs =
      ir_nodes
      |> Enum.filter(&(&1.type == :function_def))
      |> Enum.sort_by(&{span_field(&1, :start_line) || 0})

    functions = Enum.map(func_defs, &build_function(&1, graph))

    %{
      module: inspect(mod.meta[:name]),
      file: file,
      attributes: collect_module_attributes(ir_nodes),
      functions: functions
    }
  end

  defp build_module_from_funcs(func_defs, file, graph) do
    Visualize.ensure_def_cache(file)

    functions =
      func_defs
      |> Enum.sort_by(&{span_field(&1, :start_line) || 0})
      |> Enum.map(&build_function(&1, graph))

    %{
      module: nil,
      file: file,
      attributes: [],
      functions: functions
    }
  end

  defp collect_module_attributes(ir_nodes) do
    ir_nodes
    |> Enum.filter(&(&1.type == :call and &1.meta[:function] == :@))
    |> Enum.map(fn node ->
      %{
        name: format_attr_name(node),
        value: format_attr_value(node)
      }
    end)
  end

  defp format_attr_name(node) do
    case node.children do
      [%{type: :tuple, children: [%{type: :literal, meta: %{value: name}} | _]}] -> "@#{name}"
      [%{type: :literal, meta: %{value: name}}] -> "@#{name}"
      _ -> "@<attr>"
    end
  end

  defp format_attr_value(node) do
    case node.children do
      [%{type: :tuple, children: [_name | [val | _]]}] -> format_literal(val)
      [%{type: :tuple, children: [_name]}] -> nil
      [val] -> format_literal(val)
      _ -> nil
    end
  end

  defp format_literal(%{type: :literal, meta: %{value: v}}), do: inspect(v)

  defp format_literal(%{type: :tuple, children: ch}),
    do: "{" <> Enum.map_join(ch, ", ", &format_literal/1) <> "}"

  defp format_literal(%{type: :list, children: ch}),
    do: "[" <> Enum.map_join(ch, ", ", &format_literal/1) <> "]"

  defp format_literal(_), do: "..."

  # ── Function-level ──

  defp build_function(func, graph) do
    file = span_field(func, :file)
    func_start = span_field(func, :start_line) || 1
    func_end = find_func_end(file, func_start) || func_start

    source_lines = read_source_lines(file, func_start, func_end)

    function_clauses =
      func.children
      |> Enum.filter(&(&1.type == :clause and &1.meta[:kind] == :function_clause))

    if length(function_clauses) > 1 do
      build_multi_clause(func, function_clauses, source_lines, file, func_start, graph)
    else
      build_single_clause(func, source_lines, file, func_start, func_end, graph)
    end
  end

  # ── Single clause: expression nodes ──

  defp build_single_clause(func, source_lines, file, func_start, func_end, graph) do
    name = func.meta[:name]
    arity = func.meta[:arity] || 0

    expr_ranges =
      case parse_ast_expressions(file, func_start) do
        [] -> ir_expression_ranges(func, func_start, func_end)
        ranges -> ranges
      end

    {nodes, edges} =
      build_expression_graph(func.id, name, arity, expr_ranges, source_lines, func_start, func_end)

    data_edges = build_data_flow_edges(func, graph, nodes)
    edges = edges ++ data_edges

    %{
      id: to_string(func.id),
      name: to_string(name),
      arity: arity,
      nodes: nodes,
      edges: edges
    }
  end

  defp build_expression_graph(func_id, name, arity, expr_ranges, source_lines, func_start, func_end) do
    header_node = %{
      id: "#{func_id}_entry",
      type: :entry,
      label: "#{name}/#{arity}",
      start_line: func_start,
      end_line: func_start,
      source_html: highlight_range(source_lines, func_start, func_start, func_start),
      parent_id: nil
    }

    {expr_nodes, branch_edges, converge_edges} =
      build_expr_nodes_and_edges(expr_ranges, func_id, source_lines, func_start)

    end_line = find_end_keyword(source_lines, func_start) || func_end
    end_html = highlight_range(source_lines, end_line, end_line, func_start)

    exit_node = %{
      id: "#{func_id}_exit",
      type: :exit,
      label: nil,
      start_line: end_line,
      end_line: end_line,
      source_html: end_html,
      parent_id: nil
    }

    all_nodes = [header_node | expr_nodes] ++ [exit_node]
    sequential_edges = build_sequential_chain(all_nodes, branch_edges ++ converge_edges)
    all_edges = sequential_edges ++ branch_edges ++ converge_edges

    {all_nodes, all_edges}
  end

  defp build_expr_nodes_and_edges(expr_ranges, func_id, source_lines, func_start) do
    expr_ranges
    |> Enum.with_index()
    |> Enum.reduce({[], [], []}, fn {expr, idx}, {nodes, branches, converges} ->
      node_id = "#{func_id}_expr_#{idx}"
      sl = expr.start_line
      el = expr.end_line

      node = %{
        id: node_id,
        type: expr.type,
        label: nil,
        start_line: sl,
        end_line: el,
        source_html: highlight_range(source_lines, sl, el, func_start),
        parent_id: nil
      }

      {new_branch, new_converge} =
        compute_branch_edges(node, expr, expr_ranges, idx, func_id)

      {nodes ++ [node], branches ++ new_branch, converges ++ new_converge}
    end)
  end

  # ── AST-based expression parsing (from source file) ──

  defp parse_ast_expressions(file, func_start) do
    if file && File.exists?(file) do
      with {:ok, source} <- File.read(file),
           {:ok, ast} <-
             Code.string_to_quoted(source, columns: true, token_metadata: true, file: file) do
        body_ast = find_function_body_at_line(ast, func_start)
        extract_expression_ranges(body_ast)
      else
        _ -> []
      end
    else
      []
    end
  end

  defp find_function_body_at_line(ast, line) do
    {_found, body} =
      Macro.prewalk(ast, nil, fn
        {def_type, meta, [_head | rest]} = node, acc
        when def_type in [:def, :defp, :defmacro, :defmacrop] and is_nil(acc) ->
          if meta[:line] == line do
            body_kw = List.last(rest)
            {node, Keyword.get(body_kw, :do)}
          else
            {node, nil}
          end

        node, acc ->
          {node, acc}
      end)

    body
  end

  defp extract_expression_ranges(nil), do: []

  defp extract_expression_ranges({:__block__, _meta, children}) do
    children
    |> Enum.map(&classify_ast_expression/1)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_expression_ranges(single_expr) do
    [classify_ast_expression(single_expr)]
  end

  defp classify_ast_expression(ast) do
    {start_line, end_line} = ast_line_range(ast)
    type = ast_expr_type(ast)
    branch_info = ast_branch_info(ast)

    %{
      start_line: start_line,
      end_line: end_line,
      type: type,
      branch_info: branch_info
    }
  end

  defp ast_line_range(ast) do
    meta = extract_ast_meta(ast)
    start_line = meta[:line] || 1
    end_line = get_in(meta, [:end, :line]) || start_line
    {start_line, end_line}
  end

  defp extract_ast_meta({_name, meta, _args}) when is_list(meta), do: meta
  defp extract_ast_meta(_), do: []

  defp ast_expr_type({:if, _, _}), do: :branch
  defp ast_expr_type({:unless, _, _}), do: :branch
  defp ast_expr_type({:case, _, _}), do: :branch
  defp ast_expr_type({:cond, _, _}), do: :branch
  defp ast_expr_type({:with, _, _}), do: :branch
  defp ast_expr_type({:try, _, _}), do: :branch
  defp ast_expr_type({:receive, _, _}), do: :branch
  defp ast_expr_type({:=, _, _}), do: :assignment
  defp ast_expr_type({:|>, _, _}), do: :pipe
  defp ast_expr_type({:for, _, _}), do: :comprehension
  defp ast_expr_type({:fn, _, _}), do: :anonymous_fn
  defp ast_expr_type(_), do: :expression

  # ── IR-based expression parsing (fallback when no source file) ──

  defp ir_expression_ranges(func, func_start, func_end) do
    case func.children do
      [%{type: :clause, meta: %{kind: :function_clause}, children: clause_children} | _] ->
        {_params, body} = split_clause(clause_children)
        body_exprs = flatten_body(body)

        ranges =
          body_exprs
          |> Enum.map(&ir_node_to_range/1)
          |> Enum.reject(&is_nil/1)

        if ranges == [] do
          [%{start_line: func_start, end_line: func_end, type: :expression, branch_info: nil}]
        else
          ranges
        end

      [] ->
        [%{start_line: func_start, end_line: func_end, type: :expression, branch_info: nil}]
    end
  end

  defp split_clause(children) do
    {params, rest} =
      Enum.split_while(children, fn
        %{type: :guard} -> false
        %{meta: %{binding_role: :definition}} -> true
        %{type: :var} -> true
        _ -> false
      end)

    {guards, body} = Enum.split_with(rest, &(&1.type == :guard))

    body =
      body ++ Enum.flat_map(guards, & &1.children)

    {params, List.first(body) || %Reach.IR.Node{id: 0, type: :literal, meta: %{value: nil}}}
  end

  defp flatten_body(%{type: :block, children: children}), do: children
  defp flatten_body(node), do: [node]

  defp ir_node_to_range(node) do
    start_line = span_field(node, :start_line)

    if start_line do
      %{
        start_line: start_line,
        end_line: start_line,
        type: ir_node_type(node),
        branch_info: ir_branch_info(node)
      }
    else
      nil
    end
  end

  defp ir_node_type(%{type: :case}), do: :branch
  defp ir_node_type(%{type: :match}), do: :assignment
  defp ir_node_type(_), do: :expression

  defp ir_branch_info(%{type: :case, children: [_condition | clauses]}) do
    branches =
      clauses
      |> Enum.with_index()
      |> Enum.map(fn {clause, idx} ->
        {cs, ce} = ir_clause_line_range(clause)

        label =
          case clause.meta[:kind] do
            :true_branch -> "true"
            :false_branch -> "false"
            _ -> "clause #{idx + 1}"
          end

        %{label: label, range: %{start_line: cs, end_line: ce}}
      end)

    if branches == [], do: nil, else: %{kind: :case, branches: branches}
  end

  defp ir_branch_info(_), do: nil

  defp ir_clause_line_range(clause) do
    all = IR.all_nodes(clause)
    lines = Enum.map(all, &span_field(&1, :start_line)) |> Enum.reject(&is_nil/1)

    case lines do
      [] -> {1, 1}
      _ -> {Enum.min(lines), Enum.max(lines)}
    end
  end

  # ── Branch info from AST ──

  defp ast_branch_info({:if, meta, [_condition, branches]}) when is_list(branches) do
    do_body = Keyword.get(branches, :do)
    else_body = Keyword.get(branches, :else)
    do_meta = Keyword.get(meta, :do)
    end_meta = Keyword.get(meta, :end)
    build_if_branches(do_body, else_body, do_meta, end_meta)
  end

  defp ast_branch_info({:unless, meta, [_condition, branches]}) when is_list(branches) do
    do_body = Keyword.get(branches, :do)
    else_body = Keyword.get(branches, :else)
    do_meta = Keyword.get(meta, :do)
    end_meta = Keyword.get(meta, :end)
    build_if_branches(do_body, else_body, do_meta, end_meta)
  end

  defp ast_branch_info({:case, _meta, [_expr, [do: clauses]]}) when is_list(clauses) do
    build_case_branches(clauses)
  end

  defp ast_branch_info({:cond, _meta, [[do: clauses]]}) when is_list(clauses) do
    build_case_branches(clauses)
  end

  defp ast_branch_info(_), do: nil

  defp build_if_branches(do_body, else_body, do_meta, end_meta) when is_list(do_meta) do
    do_start = do_meta[:line]
    end_line = if is_list(end_meta), do: end_meta[:line], else: nil

    do_range =
      ast_body_line_range(do_body) ||
        if(do_start, do: %{start_line: do_start, end_line: do_start})

    else_range =
      ast_body_line_range(else_body) ||
        if(else_body != nil and end_line != nil,
          do: %{start_line: end_line, end_line: end_line}
        )

    branches =
      [
        %{label: "true", range: do_range},
        %{label: "false", range: else_range}
      ]
      |> Enum.reject(&is_nil(&1.range))

    if branches == [], do: nil, else: %{kind: :if, branches: branches}
  end

  defp build_if_branches(_do_body, _else_body, _do_meta, _end_meta), do: nil

  defp ast_body_line_range({_, meta, _} = ast) when is_list(meta), do: ast_line_range(ast)
  defp ast_body_line_range(_literal), do: nil

  defp build_case_branches(clauses) do
    branches =
      clauses
      |> Enum.with_index()
      |> Enum.map(fn {{:->, clause_meta, [_patterns, body]}, idx} ->
        start_l = clause_meta[:line] || 1
        end_l = ast_end_line(body) || start_l
        %{label: "clause #{idx + 1}", range: %{start_line: start_l, end_line: end_l}}
      end)

    %{kind: :case, branches: branches}
  end

  defp ast_end_line(ast) do
    meta = extract_ast_meta(ast)
    get_in(meta, [:end, :line])
  end

  # ── Edge computation ──

  defp compute_branch_edges(node, expr, all_exprs, expr_idx, func_id) do
    case expr.branch_info do
      nil ->
        {[], []}

      %{kind: _kind, branches: branches} ->
        merge_idx = find_merge_expression_index(all_exprs, expr_idx)

        branch_edges =
          branches
          |> Enum.with_index()
          |> Enum.flat_map(fn {branch, idx} ->
            target_id = find_expr_node_id_at_line(all_exprs, branch.range.start_line, func_id)

            if target_id && target_id != node.id do
              [
                %{
                  id: "branch_#{node.id}_#{idx}",
                  source: node.id,
                  target: target_id,
                  label: branch.label,
                  edge_type: :branch,
                  color: branch_color(idx)
                }
              ]
            else
              []
            end
          end)

        converge_target =
          if merge_idx do
            "#{func_id}_expr_#{merge_idx}"
          else
            "#{func_id}_exit"
          end

        converge_edges =
          branches
          |> Enum.with_index()
          |> Enum.map(fn {_branch, idx} ->
            %{
              id: "converge_#{node.id}_#{idx}",
              source: node.id,
              target: converge_target,
              label: nil,
              edge_type: :converge,
              color: "#3b82f6"
            }
          end)

        {branch_edges, converge_edges}
    end
  end

  defp find_merge_expression_index(all_exprs, current_idx) do
    current_end = Enum.at(all_exprs, current_idx).end_line

    all_exprs
    |> Enum.with_index()
    |> Enum.find_value(fn {expr, idx} ->
      if idx > current_idx and expr.start_line > current_end, do: idx
    end)
  end

  defp find_expr_node_id_at_line(all_exprs, line, func_id) do
    case Enum.find_index(all_exprs, fn expr ->
           expr.start_line <= line and expr.end_line >= line
         end) do
      nil -> nil
      idx -> "#{func_id}_expr_#{idx}"
    end
  end

  defp build_sequential_chain(all_nodes, non_seq_edges) do
    non_seq_targets = MapSet.new(non_seq_edges, & &1.target)

    all_nodes
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reject(fn [_a, b] -> MapSet.member?(non_seq_targets, b.id) end)
    |> Enum.map(fn [a, b] ->
      %{
        id: "seq_#{a.id}_#{b.id}",
        source: a.id,
        target: b.id,
        label: nil,
        edge_type: :sequential,
        color: "#94a3b8"
      }
    end)
  end

  # ── Data-flow edges ──

  defp build_data_flow_edges(_func, nil, _vis_nodes), do: []

  defp build_data_flow_edges(func, graph, vis_nodes) do
    func_nodes = IR.all_nodes(func)
    func_node_ids = MapSet.new(func_nodes, & &1.id)
    ir_to_vis = build_ir_to_vis_map(func_nodes, vis_nodes)

    graph
    |> Reach.edges()
    |> Enum.filter(fn e ->
      is_integer(e.v1) and is_integer(e.v2) and
        e.v1 in func_node_ids and e.v2 in func_node_ids and
        data_edge?(e.label)
    end)
    |> Enum.flat_map(fn e ->
      src_vis = Map.get(ir_to_vis, e.v1)
      tgt_vis = Map.get(ir_to_vis, e.v2)

      if src_vis && tgt_vis && src_vis != tgt_vis do
        [
          %{
            id: "data_#{e.v1}_#{e.v2}",
            source: src_vis,
            target: tgt_vis,
            label: extract_var_name(e.label),
            edge_type: :data,
            color: "#16a34a"
          }
        ]
      else
        []
      end
    end)
    |> Enum.uniq_by(&{&1.source, &1.target})
  end

  defp build_ir_to_vis_map(ir_nodes, vis_nodes) do
    ir_nodes
    |> Enum.reduce(%{}, fn ir_node, acc ->
      ir_line = span_field(ir_node, :start_line)

      if ir_line do
        vis =
          Enum.find(vis_nodes, fn vn ->
            vn.start_line <= ir_line and vn.end_line >= ir_line
          end)

        if vis, do: Map.put(acc, ir_node.id, vis.id), else: acc
      else
        acc
      end
    end)
  end

  defp data_edge?({:data, _}), do: true
  defp data_edge?(:match_binding), do: true
  defp data_edge?(_), do: false

  defp extract_var_name({:data, var}), do: to_string(var)
  defp extract_var_name(_), do: nil

  # ── Multi-clause dispatch ──

  defp build_multi_clause(func, clauses, source_lines, file, func_start, _graph) do
    name = func.meta[:name]
    arity = func.meta[:arity] || 0

    dispatch_source = Enum.at(source_lines, 0, "")

    dispatch_node = %{
      id: "#{func.id}_dispatch",
      type: :dispatch,
      label: "#{name}/#{arity}",
      start_line: func_start,
      end_line: func_start,
      source_html: Visualize.highlight_source(dispatch_source),
      parent_id: nil
    }

    {clause_nodes, clause_edges} =
      clauses
      |> Enum.with_index()
      |> Enum.reduce({[dispatch_node], []}, fn {clause, idx}, {nodes, edges} ->
        clause_start = span_field(clause, :start_line) || func_start
        clause_end = compute_clause_end(func, clauses, idx, file)
        clause_source = read_source_lines(file, clause_start, clause_end)
        pattern = clause_pattern(clause)

        clause_node = %{
          id: to_string(clause.id),
          type: :clause,
          label: pattern,
          start_line: clause_start,
          end_line: clause_end,
          source_html: Visualize.highlight_source(Enum.join(clause_source, "\n")),
          parent_id: nil
        }

        edge = %{
          id: "dispatch_#{func.id}_#{clause.id}",
          source: "#{func.id}_dispatch",
          target: to_string(clause.id),
          label: pattern,
          edge_type: :branch,
          color: dispatch_color(idx)
        }

        {nodes ++ [clause_node], edges ++ [edge]}
      end)

    %{
      id: to_string(func.id),
      name: to_string(name),
      arity: arity,
      nodes: clause_nodes,
      edges: clause_edges
    }
  end

  defp compute_clause_end(func, all_clauses, idx, file) do
    next_start =
      case Enum.at(all_clauses, idx + 1) do
        nil -> nil
        next -> span_field(next, :start_line)
      end

    func_end = find_func_end(file, span_field(func, :start_line) || 1)

    cond do
      next_start -> next_start - 1
      func_end -> func_end
      true -> (span_field(Enum.at(all_clauses, idx), :start_line) || 1) + 10
    end
  end

  # ── Source reading & highlighting ──

  defp read_source_lines(nil, _start, _end), do: []

  defp read_source_lines(file, start_line, end_line) when is_binary(file) do
    case File.read(file) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.slice((start_line - 1)..max(start_line - 1, end_line - 1))
        |> Enum.map(&String.trim_leading/1)

      _ ->
        []
    end
  end

  defp highlight_range(source_lines, start_line, end_line, func_start) do
    start_idx = start_line - func_start
    end_idx = end_line - func_start

    lines =
      if start_idx >= 0 and end_idx >= start_idx and source_lines != [] do
        Enum.slice(source_lines, start_idx..end_idx)
      else
        []
      end

    Visualize.highlight_source(Enum.join(lines, "\n"))
  end

  defp find_end_keyword(source_lines, func_start) do
    source_lines
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {line, idx} ->
      if String.trim(line) == "end", do: func_start + idx
    end)
  end

  # ── Helpers ──

  defp find_func_end(file, start_line) do
    cache = Process.get(:reach_def_end_cache, %{})

    case Map.get(cache, file) do
      nil -> nil
      line_map -> Map.get(line_map, start_line)
    end
  end

  defp span_field(%{source_span: %{} = span}, field), do: Map.get(span, field)
  defp span_field(_, _), do: nil

  defp clause_pattern(clause) do
    clause.children
    |> Enum.take_while(fn c ->
      c.meta[:binding_role] == :definition or
        c.type in [:literal, :tuple, :map, :list, :struct, :var]
    end)
    |> Enum.map_join(", ", &ir_label/1)
    |> case do
      "" -> "_"
      s -> s
    end
  end

  defp ir_label(%{type: :var, meta: %{name: name}}), do: to_string(name)
  defp ir_label(%{type: :literal, meta: %{value: val}}), do: inspect(val)
  defp ir_label(%{type: :tuple}), do: "{...}"
  defp ir_label(%{type: :map}), do: "%{...}"
  defp ir_label(%{type: type}), do: to_string(type)

  defp branch_color(0), do: "#16a34a"
  defp branch_color(1), do: "#dc2626"
  defp branch_color(2), do: "#ea580c"
  defp branch_color(_), do: "#7c3aed"

  defp dispatch_color(0), do: "#16a34a"
  defp dispatch_color(1), do: "#2563eb"
  defp dispatch_color(2), do: "#ea580c"
  defp dispatch_color(_), do: "#7c3aed"

  defp find_top_level_functions(all_nodes, modules) do
    module_func_ids =
      modules
      |> Enum.flat_map(fn m -> Enum.map(m.functions, & &1.id) end)
      |> MapSet.new()

    all_nodes
    |> Enum.filter(&(&1.type == :function_def))
    |> Enum.reject(&(to_string(&1.id) in module_func_ids))
    |> Enum.sort_by(&(span_field(&1, :start_line) || 0))
  end
end
