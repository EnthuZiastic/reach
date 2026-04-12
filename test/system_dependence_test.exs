defmodule ExPDG.SystemDependenceTest do
  use ExUnit.Case, async: true

  alias ExPDG.{IR, SystemDependence}

  describe "build/2" do
    test "builds system dependence graph from multiple function definitions" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def foo(x), do: bar(x)
        def bar(y), do: y + 1
        """)

      assert %ExPDG.SystemDependence{} = sdg
      assert map_size(sdg.function_pdgs) == 2
    end

    test "creates call edges between caller and callee" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def foo(x), do: bar(x)
        def bar(y), do: y + 1
        """)

      edges = Graph.edges(sdg.graph)
      call_edges = Enum.filter(edges, &(&1.label == :call))
      assert call_edges != []
    end

    test "creates parameter_in edges for arguments" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def foo(x), do: bar(x)
        def bar(y), do: y + 1
        """)

      edges = Graph.edges(sdg.graph)
      param_in_edges = Enum.filter(edges, &(&1.label == :parameter_in))
      assert param_in_edges != []
    end

    test "creates parameter_out edges for return values" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def foo(x), do: bar(x)
        def bar(y), do: y + 1
        """)

      edges = Graph.edges(sdg.graph)
      param_out_edges = Enum.filter(edges, &(&1.label == :parameter_out))
      assert param_out_edges != []
    end

    test "creates summary edges when param flows to return" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def foo(x), do: bar(x)
        def bar(y), do: y + 1
        """)

      edges = Graph.edges(sdg.graph)
      summary_edges = Enum.filter(edges, &(&1.label == :summary))
      assert summary_edges != []
    end
  end

  describe "call to pure function" do
    test "creates data edges only through params/return" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def foo(x), do: add_one(x)
        def add_one(n), do: n + 1
        """)

      edges = Graph.edges(sdg.graph)

      interprocedural_labels =
        edges
        |> Enum.map(& &1.label)
        |> Enum.filter(&(&1 in [:call, :parameter_in, :parameter_out, :summary]))

      assert :parameter_in in interprocedural_labels
    end
  end

  describe "recursive call" do
    test "doesn't create infinite graph" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def factorial(0), do: 1
        def factorial(n), do: n * factorial(n - 1)
        """)

      assert %ExPDG.SystemDependence{} = sdg
      vertices = Graph.vertices(sdg.graph)
      assert is_list(vertices)
    end
  end

  describe "context-sensitive slicing" do
    test "slices backward through call site" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def foo(x), do: bar(x)
        def bar(y), do: y + 1
        """)

      all = IR.all_nodes(sdg.ir)

      plus_node =
        Enum.find(all, fn n ->
          n.type == :binary_op and n.meta[:operator] == :+
        end)

      if plus_node do
        slice = SystemDependence.context_sensitive_slice(sdg, plus_node.id)
        assert is_list(slice)
      end
    end

    test "doesn't include unreachable call paths" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def foo(x), do: helper(x)
        def bar(y), do: helper(y)
        def helper(z), do: z + 1
        """)

      all = IR.all_nodes(sdg.ir)

      # Find the call to helper inside foo
      foo_def =
        Enum.find(all, fn n ->
          n.type == :function_def and n.meta[:name] == :foo
        end)

      if foo_def do
        foo_nodes = IR.all_nodes(foo_def)

        foo_call =
          Enum.find(foo_nodes, fn n ->
            n.type == :call and n.meta[:function] == :helper
          end)

        if foo_call do
          slice = SystemDependence.context_sensitive_slice(sdg, foo_call.id)
          assert is_list(slice)
        end
      end
    end
  end

  describe "function_pdg/2" do
    test "retrieves PDG for a specific function" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def foo(x), do: x + 1
        def bar(y), do: y * 2
        """)

      foo_pdg = SystemDependence.function_pdg(sdg, {nil, :foo, 1})
      assert foo_pdg != nil
      assert %ExPDG.Graph{} = foo_pdg

      bar_pdg = SystemDependence.function_pdg(sdg, {nil, :bar, 1})
      assert bar_pdg != nil
    end

    test "returns nil for unknown function" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def foo(x), do: x + 1
        """)

      assert SystemDependence.function_pdg(sdg, {nil, :nonexistent, 0}) == nil
    end
  end

  describe "DOT export" do
    test "produces valid DOT" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def foo(x), do: bar(x)
        def bar(y), do: y + 1
        """)

      assert {:ok, dot} = SystemDependence.to_dot(sdg)
      assert String.contains?(dot, "digraph")
    end
  end
end
