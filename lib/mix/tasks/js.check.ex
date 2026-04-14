defmodule Mix.Tasks.Js.Check do
  @moduledoc false
  use Mix.Task

  @shortdoc "Lint and format-check TypeScript assets"

  @assets_dir "assets"

  @impl true
  def run(_args) do
    run_npx(["oxfmt", "--check", "js/"], "oxfmt")
    run_npx(["oxlint", "js/"], "oxlint")
  end

  defp run_npx(args, label) do
    case System.cmd("npx", ["--yes" | args], stderr_to_stdout: true, cd: @assets_dir) do
      {output, 0} ->
        if output != "", do: IO.write(output)

      {output, _code} ->
        IO.write(output)
        Mix.raise("#{label} failed")
    end
  end
end
