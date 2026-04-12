defmodule ExPDG.Diagnostic do
  @moduledoc """
  A diagnostic produced by a check — a warning, error, or info message
  tied to a source location.
  """

  @type severity :: :error | :warning | :info

  @type t :: %__MODULE__{
          check: atom(),
          severity: severity(),
          category: atom(),
          message: String.t(),
          location: ExPDG.IR.Node.source_span() | nil,
          node_id: ExPDG.IR.Node.id() | nil,
          meta: map()
        }

  @enforce_keys [:check, :severity, :message]
  defstruct [
    :check,
    :severity,
    :message,
    category: :general,
    location: nil,
    node_id: nil,
    meta: %{}
  ]
end
