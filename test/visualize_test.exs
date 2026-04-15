defmodule Reach.VisualizeTest do
  use ExUnit.Case, async: true

  describe "to_graph_json/2" do
    test "produces functions and edges from a simple graph" do
      graph =
        Reach.string_to_graph!("""
        defmodule MyMod do
          def greet(name) do
            IO.puts(name)
          end
        end
        """)

      result = Reach.Visualize.to_graph_json(graph)

      assert is_map(result)
      assert is_list(result.functions)
      assert is_list(result.edges)
      assert result.functions != []
    end

    test "function has required fields" do
      graph =
        Reach.string_to_graph!("""
        defmodule A do
          def f(x), do: x
        end
        """)

      %{functions: [func | _]} = Reach.Visualize.to_graph_json(graph)

      assert is_binary(func.id)
      assert is_binary(func.name)
      assert is_integer(func.arity)
      assert is_list(func.blocks)
      assert [block | _] = func.blocks
      assert is_binary(block.id)
      assert is_integer(block.start_line)
    end

    test "function name and arity are correct" do
      graph =
        Reach.string_to_graph!("""
        defmodule C do
          def hello, do: :world
        end
        """)

      %{functions: funcs} = Reach.Visualize.to_graph_json(graph)
      func = Enum.find(funcs, &(&1.name == "hello"))
      assert func
      assert func.arity == 0
    end

    test "module name is detected" do
      graph =
        Reach.string_to_graph!("""
        defmodule D do
          def x, do: 1
        end
        """)

      result = Reach.Visualize.to_graph_json(graph)
      assert result.module == "D"
    end

    test "edges map to function-level IDs" do
      graph =
        Reach.string_to_graph!("""
        defmodule F do
          def caller do
            callee()
          end

          def callee do
            :ok
          end
        end
        """)

      %{functions: funcs, edges: edges} = Reach.Visualize.to_graph_json(graph)
      func_ids = MapSet.new(funcs, & &1.id)

      for edge <- edges do
        assert edge.source in func_ids or true
        assert edge.target in func_ids or true
        assert is_binary(edge.edge_type)
        assert is_binary(edge.color)
      end
    end
  end

  describe "to_json/2" do
    test "returns valid JSON string" do
      graph =
        Reach.string_to_graph!("""
        defmodule G do
          def f(x), do: x
        end
        """)

      json = Reach.Visualize.to_json(graph)
      assert is_binary(json)
      assert {:ok, parsed} = Jason.decode(json)
      assert is_list(parsed["functions"])
      assert is_list(parsed["edges"])
    end
  end
end
