defmodule Reach.PluginsTest do
  use ExUnit.Case, async: true

  describe "Ecto plugin" do
    test "tracks cast params to Repo.insert" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyApp do
            def create(params) do
              %User{}
              |> cast(params, [:name, :email])
              |> Repo.insert()
            end
          end
          """,
          plugins: [Reach.Plugins.Ecto]
        )

      edges = Reach.edges(graph)
      ecto_edges = Enum.filter(edges, &match?({:ecto_changeset_flow, _}, &1.label))
      assert ecto_edges != []
    end

    test "tracks raw SQL query params" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyApp do
            def unsafe(input) do
              Repo.query("SELECT * FROM users WHERE id = " <> input)
            end
          end
          """,
          plugins: [Reach.Plugins.Ecto]
        )

      edges = Reach.edges(graph)
      raw_edges = Enum.filter(edges, &(&1.label == :ecto_raw_query))
      assert raw_edges != []
    end
  end

  describe "Phoenix plugin" do
    test "detects action_fallback flow" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyController do
            action_fallback(ErrorController)

            def create(conn, params) do
              case do_thing(params) do
                {:ok, result} -> json(conn, result)
                {:error, changeset} -> {:error, changeset}
              end
            end
          end
          """,
          plugins: [Reach.Plugins.Phoenix]
        )

      edges = Reach.edges(graph)
      fb_edges = Enum.filter(edges, &(&1.label == :phoenix_action_fallback))
      assert fb_edges != []
    end

    test "detects socket assign flow" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyLive do
            def mount(params, session, socket) do
              assign(socket, :user, session.user)
            end
          end
          """,
          plugins: [Reach.Plugins.Phoenix]
        )

      edges = Reach.edges(graph)
      assign_edges = Enum.filter(edges, &(&1.label == :phoenix_assign))
      assert assign_edges != []
    end
  end

  describe "Oban plugin" do
    test "tracks job args in perform" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyWorker do
            def perform(job) do
              process(job)
            end
          end
          """,
          plugins: [Reach.Plugins.Oban]
        )

      edges = Reach.edges(graph)
      oban_edges = Enum.filter(edges, &(&1.label == :oban_job_args))
      assert oban_edges != []
    end
  end

  describe "GenStage plugin" do
    test "connects handle_demand to handle_events" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyStage do
            def handle_demand(demand, state) do
              {:noreply, fetch(demand), state}
            end

            def handle_events(events, _from, state) do
              process(events)
              {:noreply, [], state}
            end
          end
          """,
          plugins: [Reach.Plugins.GenStage]
        )

      edges = Reach.edges(graph)
      stage_edges = Enum.filter(edges, &(&1.label == :gen_stage_pipeline))
      assert stage_edges != []
    end

    test "connects handle_message to handle_batch" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyBroadway do
            def handle_message(_, message, _) do
              message
            end

            def handle_batch(:default, messages, _, _) do
              send_all(messages)
            end
          end
          """,
          plugins: [Reach.Plugins.GenStage]
        )

      edges = Reach.edges(graph)
      broadway_edges = Enum.filter(edges, &(&1.label == :broadway_pipeline))
      assert broadway_edges != []
    end
  end

  describe "plugin auto-detection" do
    test "detect returns list" do
      plugins = Reach.Plugin.detect()
      assert is_list(plugins)
    end

    test "plugins option overrides auto-detection" do
      assert Reach.Plugin.resolve(plugins: []) == []
      assert Reach.Plugin.resolve(plugins: [Reach.Plugins.Ecto]) == [Reach.Plugins.Ecto]
    end
  end
end
