defmodule Reach.OTP do
  @moduledoc false

  alias Reach.IR
  alias Reach.IR.Node

  @type otp_edge_label ::
          :state_read
          | :state_write
          | :state_pass
          | :init_state
          | {:call_msg, atom()}
          | {:cast_msg, atom()}
          | :call_reply
          | {:ets_dep, atom() | nil}
          | {:pdict_dep, atom() | nil}
          | :message_order
          | {:state_transition, atom(), atom()}

  # --- GenServer callbacks by {name, arity} ---

  @genserver_callbacks %{
    {:init, 1} => :init,
    {:handle_call, 3} => :handle_call,
    {:handle_cast, 2} => :handle_cast,
    {:handle_info, 2} => :handle_info,
    {:terminate, 2} => :terminate,
    {:code_change, 3} => :code_change
  }

  @doc """
  Adds OTP semantic edges to a libgraph based on IR analysis.

  Returns a new `Graph.t()` containing only OTP edges. Merge this
  with the existing PDG/SDG graph.
  """
  @spec analyze([Node.t()]) :: Graph.t()
  def analyze(ir_nodes, opts \\ []) do
    all_nodes = Keyword.get_lazy(opts, :all_nodes, fn -> IR.all_nodes(ir_nodes) end)

    Graph.new()
    |> add_genserver_edges(ir_nodes, all_nodes)
    |> add_ets_edges(all_nodes)
    |> add_process_dict_edges(all_nodes)
    |> add_message_order_edges(all_nodes)
    |> add_message_content_edges(all_nodes)
    |> add_call_reply_edges(all_nodes)
  end

  @doc """
  Detects which OTP behaviour a module uses, based on IR nodes.

  Returns `:genserver`, `:gen_statem`, `:supervisor`, `:agent`, or `nil`.
  """
  @spec detect_behaviour([Node.t()]) :: atom() | nil
  def detect_behaviour(ir_nodes) do
    all_nodes = IR.all_nodes(ir_nodes)

    use_call =
      Enum.find(all_nodes, fn node ->
        node.type == :call and
          node.meta[:function] == :use and
          node.meta[:kind] == :local
      end)

    case use_call do
      %Node{children: [%Node{type: :literal, meta: %{value: GenServer}} | _]} ->
        :genserver

      %Node{children: [%Node{meta: %{value: Supervisor}} | _]} ->
        :supervisor

      %Node{children: [%Node{meta: %{value: Agent}} | _]} ->
        :agent

      _ ->
        detect_behaviour_from_attributes(all_nodes) || detect_behaviour_from_callbacks(all_nodes)
    end
  end

  @doc """
  Classifies a function definition as a GenServer callback type.

  Returns `:init`, `:handle_call`, `:handle_cast`, `:handle_info`,
  `:terminate`, or `nil`.
  """
  @spec classify_callback(Node.t()) :: atom() | nil
  def classify_callback(%Node{type: :function_def, meta: %{name: name, arity: arity}}) do
    Map.get(@genserver_callbacks, {name, arity})
  end

  def classify_callback(_), do: nil

  @doc """
  Extracts the state parameter node from a GenServer callback.

  The state is always the last parameter in handle_call/3,
  handle_cast/2, handle_info/2, and the only param in init/1.
  """
  @spec extract_state_param(Node.t()) :: Node.t() | nil
  def extract_state_param(%Node{type: :function_def} = func_def) do
    callback_type = classify_callback(func_def)

    case {callback_type, extract_params(func_def)} do
      {:init, [arg]} -> arg
      {:handle_call, [_msg, _from, state]} -> state
      {:handle_cast, [_msg, state]} -> state
      {:handle_info, [_msg, state]} -> state
      {:terminate, [_reason, state]} -> state
      _ -> nil
    end
  end

  @doc """
  Extracts the return value expression from a GenServer callback.

  Looks for `{:reply, value, new_state}`, `{:noreply, new_state}`, etc.
  Returns `{type, reply_node, state_node}` or `nil`.
  """
  @spec extract_return_info(Node.t()) :: {atom(), Node.t() | nil, Node.t() | nil} | nil
  def extract_return_info(%Node{type: :function_def} = func_def) do
    all = IR.all_nodes(func_def)

    tuples =
      Enum.filter(all, fn node ->
        node.type == :tuple and tuple_is_genserver_return?(node)
      end)

    case tuples do
      [tuple | _] -> parse_genserver_return(tuple)
      [] -> nil
    end
  end

  # --- Private: GenServer edges ---

  defp add_genserver_edges(graph, _ir_nodes, all_nodes) do
    func_defs = Enum.filter(all_nodes, &(&1.type == :function_def))
    callbacks = Enum.filter(func_defs, &(classify_callback(&1) != nil))

    graph = add_state_flow_edges(graph, callbacks)
    add_state_pass_edges(graph, callbacks)
  end

  defp add_state_flow_edges(graph, callbacks) do
    Enum.reduce(callbacks, graph, &add_state_reads_for_callback/2)
  end

  defp add_state_reads_for_callback(callback, graph) do
    state_param = extract_state_param(callback)
    state_name = if state_param, do: var_name(state_param)

    if state_name do
      graph = Graph.add_vertex(graph, state_param.id)

      callback
      |> IR.all_nodes()
      |> Enum.filter(&state_use?(&1, state_name, state_param.id))
      |> Enum.reduce(graph, fn use_node, g ->
        g
        |> Graph.add_vertex(use_node.id)
        |> Graph.add_edge(state_param.id, use_node.id, label: :state_read)
      end)
    else
      graph
    end
  end

  defp state_use?(%Node{type: :var, meta: %{name: name}, id: id}, state_name, param_id) do
    name == state_name and id != param_id
  end

  defp state_use?(_, _, _), do: false

  defp add_state_pass_edges(graph, callbacks) do
    callbacks
    |> Enum.filter(&(classify_callback(&1) in [:handle_call, :handle_cast, :handle_info]))
    |> Enum.sort_by(& &1.id)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(graph, &connect_state_pass/2)
  end

  defp connect_state_pass([current, next], graph) do
    return_info = extract_return_info(current)
    next_state_param = extract_state_param(next)

    case {return_info, next_state_param} do
      {{_type, _reply, %Node{} = new_state}, %Node{} = next_param} ->
        graph
        |> Graph.add_vertex(new_state.id)
        |> Graph.add_vertex(next_param.id)
        |> Graph.add_edge(new_state.id, next_param.id, label: :state_pass)

      _ ->
        graph
    end
  end

  # --- Private: ETS edges ---

  defp add_ets_edges(graph, all_nodes) do
    ets_calls = Enum.filter(all_nodes, &ets_call?/1)
    writes = Enum.filter(ets_calls, &ets_write?/1)
    reads = Enum.filter(ets_calls, &ets_read?/1)

    for write <- writes,
        read <- reads,
        write.id != read.id,
        same_ets_table?(write, read),
        reduce: graph do
      g ->
        g
        |> Graph.add_vertex(write.id)
        |> Graph.add_vertex(read.id)
        |> Graph.add_edge(write.id, read.id, label: {:ets_dep, ets_table_name(write)})
    end
  end

  defp ets_call?(%Node{type: :call, meta: %{module: :ets}}), do: true
  defp ets_call?(_), do: false

  defp ets_write?(%Node{type: :call, meta: %{module: :ets, function: f}})
       when f in [:insert, :insert_new, :delete, :delete_object, :update_counter, :update_element],
       do: true

  defp ets_write?(_), do: false

  defp ets_read?(%Node{type: :call, meta: %{module: :ets, function: f}})
       when f in [:lookup, :lookup_element, :match, :match_object, :select, :member, :info],
       do: true

  defp ets_read?(_), do: false

  defp same_ets_table?(a, b) do
    table_a = ets_table_name(a)
    table_b = ets_table_name(b)
    table_a != nil and table_a == table_b
  end

  defp ets_table_name(%Node{children: [%Node{type: :literal, meta: %{value: name}} | _]})
       when is_atom(name),
       do: name

  defp ets_table_name(%Node{children: [%Node{type: :var, meta: %{name: name}} | _]}),
    do: name

  defp ets_table_name(_), do: nil

  # --- Private: process dictionary edges ---

  defp add_process_dict_edges(graph, all_nodes) do
    writes = Enum.filter(all_nodes, &pdict_write?/1)
    reads = Enum.filter(all_nodes, &pdict_read?/1)

    for write <- writes,
        read <- reads,
        write.id != read.id,
        same_pdict_key?(write, read),
        reduce: graph do
      g ->
        g
        |> Graph.add_vertex(write.id)
        |> Graph.add_vertex(read.id)
        |> Graph.add_edge(write.id, read.id, label: {:pdict_dep, pdict_key(write)})
    end
  end

  defp pdict_write?(%Node{type: :call, meta: %{module: Process, function: :put}}), do: true
  defp pdict_write?(%Node{type: :call, meta: %{module: Process, function: :delete}}), do: true
  defp pdict_write?(_), do: false

  defp pdict_read?(%Node{type: :call, meta: %{module: Process, function: :get}}), do: true
  defp pdict_read?(%Node{type: :call, meta: %{module: Process, function: :get_keys}}), do: true
  defp pdict_read?(_), do: false

  defp same_pdict_key?(write, read) do
    key_w = pdict_key(write)
    key_r = pdict_key(read)
    key_w == nil or key_r == nil or key_w == key_r
  end

  defp pdict_key(%Node{children: [%Node{type: :literal, meta: %{value: key}} | _]}), do: key
  defp pdict_key(_), do: nil

  # --- Private: message ordering ---

  defp add_message_order_edges(graph, all_nodes) do
    sends =
      all_nodes
      |> Enum.filter(&send_call?/1)
      |> Enum.sort_by(& &1.id)

    sends
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(graph, fn [a, b], g ->
      if same_send_target?(a, b) do
        g
        |> Graph.add_vertex(a.id)
        |> Graph.add_vertex(b.id)
        |> Graph.add_edge(a.id, b.id, label: :message_order)
      else
        g
      end
    end)
  end

  defp send_call?(%Node{type: :call, meta: %{function: :send, kind: :local}}), do: true
  defp send_call?(%Node{type: :call, meta: %{module: Process, function: :send}}), do: true

  defp send_call?(%Node{type: :call, meta: %{module: GenServer, function: f}})
       when f in [:call, :cast],
       do: true

  defp send_call?(_), do: false

  defp same_send_target?(a, b) do
    target_a = send_target(a)
    target_b = send_target(b)
    target_a != nil and target_a == target_b
  end

  defp send_target(%Node{children: [%Node{type: :var, meta: %{name: name}} | _]}), do: name

  defp send_target(%Node{children: [%Node{type: :literal, meta: %{value: val}} | _]}), do: val

  defp send_target(_), do: nil

  # --- GenServer.call reply flow ---

  defp add_call_reply_edges(graph, all_nodes) do
    # Find GenServer.call sites
    call_sites =
      Enum.filter(all_nodes, fn node ->
        node.type == :call and
          node.meta[:module] == GenServer and
          node.meta[:function] == :call
      end)

    # Find handle_call functions with {:reply, value, state} returns
    reply_nodes = find_reply_values(all_nodes)

    for call_site <- call_sites,
        {_tag, reply_value} <- reply_nodes,
        reduce: graph do
      g ->
        g
        |> Graph.add_vertex(reply_value.id)
        |> Graph.add_vertex(call_site.id)
        |> Graph.add_edge(reply_value.id, call_site.id, label: :call_reply)
    end
  end

  defp find_reply_values(all_nodes) do
    all_nodes
    |> Enum.filter(fn node ->
      node.type == :function_def and node.meta[:name] == :handle_call
    end)
    |> Enum.flat_map(fn func_def ->
      func_def
      |> IR.all_nodes()
      |> Enum.filter(fn node ->
        node.type == :tuple and
          match?([%{type: :literal, meta: %{value: :reply}} | _], node.children)
      end)
      |> Enum.flat_map(fn tuple ->
        case tuple.children do
          [_, reply_value | _] -> [{:reply, reply_value}]
          _ -> []
        end
      end)
    end)
  end

  # --- Message content flow ---

  defp add_message_content_edges(graph, all_nodes) do
    sends = Enum.filter(all_nodes, &send_with_payload?/1)
    handlers = find_message_handlers(all_nodes)

    for send_node <- sends,
        {handler_def, pattern_vars} <- handlers,
        {tag, payload_nodes} = extract_send_payload(send_node),
        tag != nil,
        {handler_tag, handler_vars} <- [{extract_handler_tag(handler_def), pattern_vars}],
        tag == handler_tag,
        payload <- payload_nodes,
        var <- handler_vars,
        reduce: graph do
      g ->
        g
        |> Graph.add_vertex(payload.id)
        |> Graph.add_vertex(var.id)
        |> Graph.add_edge(payload.id, var.id, label: {:message_content, tag})
    end
  end

  defp send_with_payload?(%Node{
         type: :call,
         meta: %{function: :send, kind: :local},
         children: [_, _]
       }),
       do: true

  defp send_with_payload?(%Node{
         type: :call,
         meta: %{module: Process, function: :send},
         children: [_, _]
       }),
       do: true

  defp send_with_payload?(%Node{
         type: :call,
         meta: %{module: GenServer, function: f},
         children: [_, _ | _]
       })
       when f in [:call, :cast],
       do: true

  defp send_with_payload?(_), do: false

  defp extract_send_payload(%Node{children: [_target, payload | _]}) do
    case payload do
      %Node{type: :tuple, children: [%Node{type: :literal, meta: %{value: tag}} | rest]}
      when is_atom(tag) ->
        {tag, rest}

      %Node{type: :literal, meta: %{value: tag}} when is_atom(tag) ->
        {tag, []}

      _ ->
        {nil, []}
    end
  end

  defp find_message_handlers(all_nodes) do
    all_nodes
    |> Enum.filter(fn node ->
      node.type == :function_def and
        node.meta[:name] in [:handle_info, :handle_cast, :handle_call]
    end)
    |> Enum.flat_map(fn func_def ->
      func_def.children
      |> Enum.filter(&(&1.type == :clause))
      |> Enum.map(fn clause ->
        pattern_vars =
          clause.children
          |> Enum.take_while(&(&1.type != :guard))
          |> Enum.flat_map(&collect_pattern_vars/1)

        {clause, pattern_vars}
      end)
    end)
  end

  defp extract_handler_tag(%Node{type: :clause, children: [first | _]}) do
    case first do
      %Node{type: :tuple, children: [%Node{type: :literal, meta: %{value: tag}} | _]}
      when is_atom(tag) ->
        tag

      %Node{type: :literal, meta: %{value: tag}} when is_atom(tag) ->
        tag

      _ ->
        nil
    end
  end

  defp collect_pattern_vars(%Node{type: :var, meta: %{binding_role: :definition}} = node) do
    [node]
  end

  defp collect_pattern_vars(%Node{children: children}) do
    Enum.flat_map(children, &collect_pattern_vars/1)
  end

  defp collect_pattern_vars(_), do: []

  # --- Private: helpers ---

  defp extract_params(%Node{
         type: :function_def,
         meta: %{arity: arity},
         children: [%Node{type: :clause, children: children} | _]
       }) do
    Enum.take(children, arity)
  end

  defp extract_params(_), do: []

  defp var_name(%Node{type: :var, meta: %{name: name}}), do: name
  defp var_name(_), do: nil

  defp tuple_is_genserver_return?(%Node{type: :tuple, children: children}) do
    case children do
      [%Node{type: :literal, meta: %{value: tag}} | _] when tag in [:reply, :noreply, :stop] ->
        true

      _ ->
        false
    end
  end

  defp parse_genserver_return(%Node{type: :tuple, children: children}) do
    case children do
      [%Node{meta: %{value: :reply}}, reply, new_state | _] ->
        {:reply, reply, new_state}

      [%Node{meta: %{value: :noreply}}, new_state | _] ->
        {:noreply, nil, new_state}

      [%Node{meta: %{value: :stop}}, _reason, new_state | _] ->
        {:stop, nil, new_state}

      [%Node{meta: %{value: :stop}}, _reason] ->
        {:stop, nil, nil}

      _ ->
        nil
    end
  end

  defp detect_behaviour_from_attributes(all_nodes) do
    has_gen_statem_behaviour =
      Enum.any?(all_nodes, fn node ->
        (node.type == :compiler_directive and node.meta[:directive] == :behaviour and
           match?([%{type: :literal, meta: %{value: :gen_statem}}], node.children)) or
          (node.type == :call and node.meta[:function] == :@ and
             match?(
               [
                 %{
                   type: :call,
                   meta: %{function: :behaviour},
                   children: [%{type: :literal, meta: %{value: :gen_statem}}]
                 }
               ],
               node.children
             ))
      end)

    if has_gen_statem_behaviour, do: :gen_statem
  end

  defp detect_behaviour_from_callbacks(all_nodes) do
    func_defs = Enum.filter(all_nodes, &(&1.type == :function_def))

    has_callback_mode =
      Enum.any?(func_defs, fn fd ->
        fd.meta[:name] == :callback_mode and fd.meta[:arity] == 0
      end)

    has_genserver_callbacks =
      Enum.any?(func_defs, fn fd ->
        classify_callback(fd) in [:handle_call, :handle_cast, :handle_info]
      end)

    cond do
      has_callback_mode -> :gen_statem
      has_genserver_callbacks -> :genserver
      true -> nil
    end
  end

  # --- gen_statem analysis ---

  @doc """
  Extracts gen_statem state machine information from module IR nodes.

  Returns a map with `:callback_mode`, `:states`, and `:transitions`.
  Each state has its event handlers. Each transition has source, target,
  event type, and the function node that triggers it.
  """
  @spec analyze_gen_statem([Node.t()]) :: map() | nil
  def analyze_gen_statem(ir_nodes) do
    all_nodes = IR.all_nodes(ir_nodes)
    func_defs = Enum.filter(all_nodes, &(&1.type == :function_def))

    callback_mode = detect_callback_mode(func_defs)
    if callback_mode == nil, do: throw(:not_gen_statem)

    {states, transitions} =
      case callback_mode do
        :state_functions -> analyze_state_functions(func_defs, all_nodes)
        :handle_event_function -> analyze_handle_event_function(func_defs, all_nodes)
      end

    init_state = extract_init_state(func_defs, all_nodes)

    %{
      callback_mode: callback_mode,
      init_state: init_state,
      states: states,
      transitions: transitions
    }
  catch
    :not_gen_statem -> nil
  end

  defp detect_callback_mode(func_defs) do
    cm_func = Enum.find(func_defs, &(&1.meta[:name] == :callback_mode and &1.meta[:arity] == 0))

    case cm_func do
      nil ->
        nil

      func ->
        all = IR.all_nodes(func)

        cond do
          has_literal?(all, :state_functions) -> :state_functions
          has_literal?(all, :handle_event_function) -> :handle_event_function
          true -> :state_functions
        end
    end
  end

  defp has_literal?(nodes, value) do
    Enum.any?(nodes, &(&1.type == :literal and &1.meta[:value] == value))
  end

  defp extract_init_state(func_defs, all_nodes) do
    init = Enum.find(func_defs, &(&1.meta[:name] == :init))
    if init == nil, do: throw(:not_gen_statem)

    attr_values = resolve_module_attributes(all_nodes)

    init
    |> IR.all_nodes()
    |> Enum.flat_map(&extract_init_ok_state(&1, attr_values))
    |> Enum.uniq()
    |> case do
      [single] -> single
      multiple when multiple != [] -> multiple
      [] -> nil
    end
  end

  defp extract_init_ok_state(
         %{type: :tuple, children: [%{type: :literal, meta: %{value: :ok}}, state_node, _ | _]},
         attr_values
       ) do
    case state_node |> extract_state_literal() |> resolve_attr(attr_values) do
      val when is_atom(val) and val != :any -> [val]
      _ -> []
    end
  end

  defp extract_init_ok_state(_, _), do: []

  defp analyze_state_functions(func_defs, _all_nodes) do
    known_callbacks =
      MapSet.new([:init, :callback_mode, :terminate, :code_change, :format_status])

    state_funcs =
      func_defs
      |> Enum.filter(fn fd ->
        fd.meta[:name] not in known_callbacks and
          fd.meta[:arity] == 3 and
          fd.meta[:kind] != :defp and
          has_statem_return?(fd)
      end)
      |> Enum.group_by(& &1.meta[:name])

    states =
      Map.new(state_funcs, fn {state_name, funcs} ->
        events = Enum.flat_map(funcs, &extract_state_func_events/1)
        {state_name, %{events: events}}
      end)

    transitions =
      state_funcs
      |> Enum.flat_map(fn {state_name, funcs} ->
        Enum.flat_map(funcs, fn func ->
          extract_transitions(func, state_name)
        end)
      end)

    {states, transitions}
  end

  defp extract_state_func_events(func) do
    func.children
    |> Enum.filter(&(&1.type == :clause))
    |> Enum.map(fn clause ->
      params = Enum.take(clause.children, 3)
      event_type = extract_event_type(Enum.at(params, 0))
      %{event_type: event_type, node: func}
    end)
  end

  defp analyze_handle_event_function(func_defs, all_nodes) do
    he_funcs =
      Enum.filter(func_defs, fn fd ->
        fd.meta[:name] == :handle_event and fd.meta[:arity] == 4
      end)

    attr_values = resolve_module_attributes(all_nodes)

    clauses =
      Enum.flat_map(he_funcs, fn func ->
        func.children
        |> Enum.filter(&(&1.type == :clause))
        |> Enum.map(&{func, &1})
      end)

    state_events =
      clauses
      |> Enum.map(fn {func, clause} ->
        params = Enum.take(clause.children, 4)
        event_type = extract_event_type(Enum.at(params, 0))
        state = extract_state_literal(Enum.at(params, 2)) |> resolve_attr(attr_values)
        {state, event_type, func}
      end)
      |> Enum.group_by(fn {state, _, _} -> state end)

    states =
      Map.new(state_events, fn {state, entries} ->
        events =
          Enum.map(entries, fn {_, event_type, func} ->
            %{event_type: event_type, node: func}
          end)

        {state, %{events: events}}
      end)

    transitions =
      Enum.flat_map(he_funcs, fn func ->
        func.children
        |> Enum.filter(&(&1.type == :clause))
        |> Enum.flat_map(fn clause ->
          params = Enum.take(clause.children, 4)
          state = extract_state_literal(Enum.at(params, 2)) |> resolve_attr(attr_values)
          extract_transitions_from_body(clause, state)
        end)
      end)

    {states, transitions}
  end

  defp extract_event_type(nil), do: :unknown

  defp extract_event_type(%{type: :literal, meta: %{value: val}}) when is_atom(val), do: val

  defp extract_event_type(%{
         type: :tuple,
         children: [%{type: :literal, meta: %{value: :call}}, _]
       }),
       do: {:call, :from}

  defp extract_event_type(%{
         type: :tuple,
         children: [
           %{type: :literal, meta: %{value: :timeout}},
           %{type: :literal, meta: %{value: name}}
         ]
       }),
       do: {:timeout, name}

  defp extract_event_type(%{type: :var}), do: :any
  defp extract_event_type(_), do: :unknown

  defp extract_state_literal(nil), do: :any
  defp extract_state_literal(%{type: :literal, meta: %{value: val}}) when is_atom(val), do: val
  defp extract_state_literal(%{type: :var, meta: %{name: :_}}), do: :any
  defp extract_state_literal(%{type: :var}), do: :any

  defp extract_state_literal(%{type: :call, meta: %{function: :@}} = node) do
    case node.children do
      [%{type: :var, meta: %{name: attr_name}}] -> {:module_attribute, attr_name}
      [%{type: :literal, meta: %{value: attr_name}}] -> {:module_attribute, attr_name}
      _ -> :any
    end
  end

  defp extract_state_literal(_), do: :any

  defp resolve_module_attributes(all_nodes) do
    all_nodes
    |> Enum.flat_map(fn
      %{
        type: :call,
        meta: %{function: :@},
        children: [
          %{
            type: :call,
            meta: %{function: name},
            children: [%{type: :literal, meta: %{value: value}}]
          }
        ]
      } ->
        [{name, value}]

      _ ->
        []
    end)
    |> Map.new()
  end

  defp resolve_attr({:module_attribute, name}, attr_values),
    do: Map.get(attr_values, name, {:module_attribute, name})

  defp resolve_attr(other, _), do: other

  defp extract_transitions(func, from_state) do
    func
    |> IR.all_nodes()
    |> find_next_state_tuples()
    |> Enum.map(fn {to_state, event_type} ->
      %{from: from_state, to: to_state, trigger: event_type, node: func}
    end)
  end

  defp extract_transitions_from_body(clause, from_state) do
    clause
    |> IR.all_nodes()
    |> find_next_state_tuples()
    |> Enum.map(fn {to_state, _} ->
      event_type = extract_event_type(Enum.at(clause.children, 0))
      %{from: from_state || :any, to: to_state, trigger: event_type, node: clause}
    end)
  end

  defp find_next_state_tuples(all_nodes) do
    all_nodes
    |> Enum.filter(fn node ->
      node.type == :tuple and
        match?(
          [%{type: :literal, meta: %{value: :next_state}} | _],
          node.children
        )
    end)
    |> Enum.flat_map(fn tuple ->
      case tuple.children do
        [_, %{type: :literal, meta: %{value: to_state}}, _ | rest] when is_atom(to_state) ->
          event_type = extract_event_from_actions(rest)
          [{to_state, event_type}]

        _ ->
          []
      end
    end)
    |> Enum.uniq()
  end

  defp extract_event_from_actions(_), do: nil

  @statem_return_tags [:next_state, :keep_state, :stop, :stop_and_reply, :repeat_state]
  @statem_return_atoms [:keep_state_and_data, :repeat_state_and_data, :stop]

  defp has_statem_return?(func) do
    func
    |> IR.all_nodes()
    |> Enum.any?(fn node ->
      (node.type == :tuple and
         match?(
           [%{type: :literal, meta: %{value: tag}} | _] when tag in @statem_return_tags,
           node.children
         )) or
        (node.type == :literal and node.meta[:value] in @statem_return_atoms)
    end)
  end
end
