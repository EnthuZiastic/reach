defmodule ExPDG.Checks.TaintFlow do
  @moduledoc """
  Detects data flow from taint sources to dangerous sinks.

  Taint sources: user input functions (Plug.Conn.params, etc.)
  Dangerous sinks: SQL execution, system commands, code eval, etc.

  This is the foundation for SQL injection, command injection,
  and eval injection checks.
  """

  @behaviour ExPDG.Check

  @taint_sources [
    {Plug.Conn, :params},
    {Plug.Conn, :query_params},
    {Plug.Conn, :body_params},
    {Plug.Conn, :path_params}
  ]

  @dangerous_sinks [
    {System, :cmd},
    {System, :shell},
    {Ecto.Adapters.SQL, :query},
    {Ecto.Adapters.SQL, :query!},
    {Code, :eval_string},
    {Code, :eval_quoted},
    {:os, :cmd}
  ]

  @impl true
  def meta, do: %{severity: :error, category: :security}

  @impl true
  def run(graph, _opts) do
    import ExPDG.Query

    all = nodes(graph)

    sources =
      Enum.filter(all, fn node ->
        node.type == :call and
          {node.meta[:module], node.meta[:function]} in @taint_sources
      end)

    sinks =
      Enum.filter(all, fn node ->
        node.type == :call and
          {node.meta[:module], node.meta[:function]} in @dangerous_sinks
      end)

    for source <- sources,
        sink <- sinks,
        data_flows?(graph, source.id, sink.id) do
      source_loc = format_location(source.source_span)
      sink_loc = format_location(sink.source_span)

      %ExPDG.Diagnostic{
        check: :taint_flow,
        severity: :error,
        category: :security,
        message: "Unsanitized input flows from #{source_loc} to #{sink_loc}",
        location: sink.source_span,
        node_id: sink.id,
        meta: %{source_id: source.id, sink_id: sink.id}
      }
    end
  end

  defp format_location(nil), do: "unknown"
  defp format_location(%{file: file, start_line: line}), do: "#{file}:#{line}"
end
