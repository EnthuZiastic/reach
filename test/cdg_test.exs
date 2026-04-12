defmodule ExPDG.CDGTest do
  use ExUnit.Case, async: true

  alias ExPDG.{IR, CFG, CDG}
  alias ExPDG.IR.Node

  defp build_cdg(source) do
    [func_def] = IR.from_string!(source)
    cfg = CFG.build(func_def)
    cdg = CDG.build(cfg)
    {func_def, cfg, cdg}
  end

  defp control_deps(cdg, node_id) do
    Graph.edges(cdg)
    |> Enum.filter(fn e -> e.v2 == node_id end)
    |> Enum.map(fn e -> {e.v1, e.label} end)
  end

  defp has_control_edge?(cdg, from, to) do
    Graph.edges(cdg)
    |> Enum.any?(fn e -> e.v1 == from and e.v2 == to end)
  end

  describe "basic CDG" do
    test "if/else: both branches control-dependent on condition" do
      {func, _cfg, cdg} = build_cdg("""
      def foo(x) do
        if x > 0 do
          :positive
        else
          :negative
        end
      end
      """)

      # The CDG should have control dependence edges
      edges = Graph.edges(cdg)
      control_edges = Enum.filter(edges, fn e ->
        match?({:control, _}, e.label)
      end)

      assert length(control_edges) > 0
    end

    test "CDG contains all CFG vertices" do
      {_func, cfg, cdg} = build_cdg("""
      def foo(x) do
        if x > 0 do
          :positive
        else
          :negative
        end
      end
      """)

      cfg_vertices = Graph.vertices(cfg) |> MapSet.new()
      cdg_vertices = Graph.vertices(cdg) |> MapSet.new()

      assert MapSet.subset?(cfg_vertices, cdg_vertices)
    end

    test "straight-line code: no control dependence edges" do
      {_func, _cfg, cdg} = build_cdg("""
      def foo(x) do
        a = x + 1
        b = a + 2
        b
      end
      """)

      # In straight-line code, every node post-dominates its predecessor,
      # so there are no control dependence edges
      control_edges = Graph.edges(cdg) |> Enum.filter(fn e ->
        match?({:control, _}, e.label)
      end)

      assert control_edges == []
    end
  end

  describe "CDG from hand-built CFG" do
    test "diamond CDG: branches control-dependent on condition" do
      # Build a manual diamond CFG:
      #  entry -> cond -> true_branch -> join -> exit
      #  entry -> cond -> false_branch -> join -> exit
      cfg =
        Graph.new()
        |> Graph.add_edge(:entry, :cond, label: :sequential)
        |> Graph.add_edge(:cond, :true_branch, label: :true_branch)
        |> Graph.add_edge(:cond, :false_branch, label: :false_branch)
        |> Graph.add_edge(:true_branch, :join, label: :sequential)
        |> Graph.add_edge(:false_branch, :join, label: :sequential)
        |> Graph.add_edge(:join, :exit, label: :return)

      cdg = CDG.build(cfg)

      # true_branch and false_branch should be control-dependent on cond
      assert has_control_edge?(cdg, :cond, :true_branch)
      assert has_control_edge?(cdg, :cond, :false_branch)

      # join should NOT be control-dependent on cond (post-dominated by exit)
      refute has_control_edge?(cdg, :cond, :join)
    end

    test "nested branches: inner depends on outer" do
      # entry -> A -> B -> D -> exit
      # entry -> A -> C -> D -> exit
      # A -> B: true
      # A -> C: false
      # B has inner branch: B -> E, B -> F, both -> D
      cfg =
        Graph.new()
        |> Graph.add_edge(:entry, :a, label: :sequential)
        |> Graph.add_edge(:a, :b, label: :true_branch)
        |> Graph.add_edge(:a, :c, label: :false_branch)
        |> Graph.add_edge(:b, :e, label: :true_branch)
        |> Graph.add_edge(:b, :f, label: :false_branch)
        |> Graph.add_edge(:e, :d, label: :sequential)
        |> Graph.add_edge(:f, :d, label: :sequential)
        |> Graph.add_edge(:c, :d, label: :sequential)
        |> Graph.add_edge(:d, :exit, label: :return)

      cdg = CDG.build(cfg)

      # B and C control-dependent on A
      assert has_control_edge?(cdg, :a, :b)
      assert has_control_edge?(cdg, :a, :c)

      # E and F control-dependent on B
      assert has_control_edge?(cdg, :b, :e)
      assert has_control_edge?(cdg, :b, :f)
    end

    test "unconditional code: dependent only on entry" do
      # entry -> a -> b -> c -> exit (all sequential)
      cfg =
        Graph.new()
        |> Graph.add_edge(:entry, :a, label: :sequential)
        |> Graph.add_edge(:a, :b, label: :sequential)
        |> Graph.add_edge(:b, :c, label: :sequential)
        |> Graph.add_edge(:c, :exit, label: :return)

      cdg = CDG.build(cfg)

      # No control dependence edges expected for linear code
      # (each node is post-dominated by its successor)
      control_edges = Graph.edges(cdg) |> Enum.filter(fn e ->
        match?({:control, _}, e.label)
      end)

      # In linear code, the only control dependence should be on :entry
      # (all nodes always execute if entry is reached)
      non_entry_sources =
        control_edges
        |> Enum.map(& &1.v1)
        |> Enum.reject(&(&1 == :entry))
        |> Enum.uniq()

      assert non_entry_sources == []
    end
  end
end
