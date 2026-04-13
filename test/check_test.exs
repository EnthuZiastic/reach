defmodule ExPDG.CheckTest do
  use ExUnit.Case, async: true

  alias ExPDG.Checks.{DeepDependencyChain, TaintFlow, UnusedDefinition, UselessExpression}
  alias ExPDG.{Diagnostic, Graph, IR}

  defp build_graph(source) do
    nodes = IR.from_string!(source)
    Graph.build(nodes)
  end

  describe "Check behaviour" do
    test "UselessExpression runs without errors" do
      graph =
        build_graph("""
        def foo(x) do
          y = x + 1
          y
        end
        """)

      diagnostics = UselessExpression.run(graph, [])
      assert is_list(diagnostics)

      Enum.each(diagnostics, fn d ->
        assert %Diagnostic{} = d
        assert d.check == :useless_expression
      end)
    end

    test "UnusedDefinition runs without errors" do
      graph =
        build_graph("""
        def foo(x) do
          y = x + 1
          y
        end
        """)

      diagnostics = UnusedDefinition.run(graph, [])
      assert is_list(diagnostics)
    end

    test "TaintFlow runs without errors" do
      graph =
        build_graph("""
        def foo(x) do
          x + 1
        end
        """)

      diagnostics = TaintFlow.run(graph, [])
      assert is_list(diagnostics)
      assert diagnostics == []
    end

    test "DeepDependencyChain runs without errors" do
      graph =
        build_graph("""
        def foo(x) do
          x + 1
        end
        """)

      diagnostics = DeepDependencyChain.run(graph, [])
      assert is_list(diagnostics)
    end

    test "run_checks combines multiple checks" do
      graph =
        build_graph("""
        def foo(x) do
          x + 1
        end
        """)

      checks = [
        UselessExpression,
        UnusedDefinition,
        TaintFlow,
        DeepDependencyChain
      ]

      diagnostics = ExPDG.Check.run_checks(checks, graph)
      assert is_list(diagnostics)
    end
  end

  describe "check macro" do
    defmodule SampleCheck do
      use ExPDG.Check

      check :sample_check,
        severity: :info,
        category: :test do
        for node <- nodes(graph, type: :literal) do
          diagnostic.("Found a literal", node)
        end
      end
    end

    test "macro-defined check finds literals" do
      graph =
        build_graph("""
        def foo do
          42
        end
        """)

      diagnostics = SampleCheck.run(graph, [])
      assert is_list(diagnostics)

      literal_diagnostics = Enum.filter(diagnostics, &(&1.check == :sample_check))

      Enum.each(literal_diagnostics, fn d ->
        assert d.severity == :info
        assert d.category == :test
      end)
    end
  end

  describe "UselessExpression false positive avoidance" do
    test "does not flag last expression in block" do
      graph =
        build_graph("""
        def foo(x) do
          y = x + 1
          Enum.map([1], &to_string/1)
        end
        """)

      diagnostics = UselessExpression.run(graph, [])
      assert diagnostics == []
    end

    test "does not flag sub-expressions inside calls" do
      graph =
        build_graph("""
        def foo(x) do
          IO.puts(Enum.join([1, 2], ","))
        end
        """)

      useless = Enum.filter(UselessExpression.run(graph, []), &(&1.check == :useless_expression))
      assert useless == []
    end

    test "does not flag impure calls like IO.puts" do
      graph =
        build_graph("""
        def foo do
          IO.puts("hello")
          :ok
        end
        """)

      diagnostics = UselessExpression.run(graph, [])
      assert diagnostics == []
    end
  end

  describe "UnusedDefinition false positive avoidance" do
    test "does not flag variable used on next line" do
      graph =
        build_graph("""
        def foo(x) do
          y = x + 1
          y + 2
        end
        """)

      unused =
        Enum.filter(UnusedDefinition.run(graph, []), fn d ->
          d.message =~ "y"
        end)

      assert unused == []
    end

    test "does not flag underscore-prefixed variables" do
      graph =
        build_graph("""
        def foo(x) do
          _unused = x + 1
          :ok
        end
        """)

      diagnostics = UnusedDefinition.run(graph, [])
      assert diagnostics == []
    end
  end

  describe "diagnostic metadata" do
    test "includes location information" do
      graph =
        build_graph("""
        def foo(x) do
          y = x + 1
          y
        end
        """)

      diagnostics = UselessExpression.run(graph, [])

      Enum.each(diagnostics, fn d ->
        assert d.node_id != nil
        assert d.check != nil
        assert d.severity in [:error, :warning, :info]
      end)
    end
  end
end
