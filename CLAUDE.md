# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Reach is a standalone Elixir library that builds a **Program Dependence Graph (PDG)** from Elixir, Erlang, Gleam, JavaScript/TypeScript source, and BEAM bytecode, then exposes analyses (slicing, taint, independence, dead code, smells, OTP coupling) via an Elixir API and a suite of `mix reach.*` tasks. There is no Phoenix/web service here — the only HTTP surface is a static interactive HTML/Vue report rendered from `priv/template.html.eex` + `assets/`.

The repo is published as the `:reach` Hex package. It is unrelated to the EnthuZiastic platform repos under `~/code/` even though it sits there.

`AGENTS.md` is the authoritative spec for visualization invariants ("Block Quality Acceptance Criteria") and the per-task CLI table — read it before touching anything under `lib/reach/visualize/` or `assets/js/`. Do not duplicate that content here.

## Toolchain

- Elixir `~> 1.18` (`.tool-versions` pins `elixir 1.19.5-otp-27`).
- Optional deps gate features: `:boxart` (terminal graphs), `:jason` (JSON output), `:makeup*` (syntax highlighting in HTML report), `:quickbeam` (extra plugin). Code must guard their usage with `Code.ensure_loaded?/1` — see commit `d4af26c` for the pattern.
- `:volt` is the asset bundler used in dev only; the `assets.build` alias drives it.

## Commands

```bash
mix deps.get
mix compile

# Full CI pipeline — same gates that run on PRs
mix ci
# = compile --warnings-as-errors → format --check-formatted → js.check
#   → credo --strict → ex_dna (clone detection) → dialyzer → test

# Tests
mix test                                       # full suite
mix test test/smell_test.exs                   # one file
mix test test/visualize/block_quality_test.exs:42   # one line
mix test --only <tag>

# Lint / static
mix format
mix credo --strict
mix dialyzer        # PLT cached at _build/dev/dialyxir_plt.plt
mix ex_dna          # clone/duplication check — used in `mix ci`
mix js.check        # custom task; lint/format under assets/

# Frontend bundle for the HTML report
mix assets.build    # volt.build → priv/static/reach.{js,css}

# Run the tool against a project
mix reach <path-or-module>          # opens an interactive HTML report
mix reach.modules --sort complexity
mix reach.smell
mix reach.otp --graph
```

All `mix reach.*` analysis tasks share `--format text|json|oneline` and many accept `--graph` (requires `:boxart`). Full task list lives in `AGENTS.md`.

## Architecture pipeline

```
Source (.ex/.erl/.gleam/.js/.ts/.beam)
   │
   ▼ lib/reach/frontend/{elixir,erlang,gleam,javascript,beam}.ex
IR nodes (lib/reach/ir/*.ex — Reach.IR.Node)
   │
   ▼ lib/reach/control_flow.ex
Control Flow Graph (per-function DAG, never cyclic)
   │
   ├─► lib/reach/dominator.ex          → idom / postdom / dominator tree / DF
   │       │
   │       ▼
   │   lib/reach/control_dependence.ex
   │
   └─► lib/reach/data_dependence.ex    → def-use chains
            │
            ▼
   lib/reach/program_dependence.ex     → PDG
            │
            ▼
   lib/reach/system_dependence.ex      → SDG: PDGs joined by call/summary edges
            │                              + OTP edges from lib/reach/otp/*.ex
            │                              + plugin edges from lib/reach/plugins/*.ex
            ▼
   Queries: backward_slice, forward_slice, taint_analysis, independent?
            (entry points in lib/reach.ex)
```

Key implications:

- **Frontends are interchangeable.** All five emit the same `Reach.IR.Node` shape, so every downstream pass works uniformly across languages. When adding a new frontend, match the IR contract first; do not extend downstream passes to special-case a new node type.
- **The BEAM frontend sees macro-expanded code** (GenServer callbacks, generated functions). Expect it to surface nodes that source frontends cannot. OTP analyses lean on this.
- **Plugins (`lib/reach/plugins/*.ex`) attach extra edges to the SDG** — Phoenix routes, Ecto query/repo coupling, Oban jobs, OpenTelemetry spans, Ash, Jido, GenStage, QuickBEAM. They run after the SDG is built and must not mutate IR/CFG.
- **OTP module is split into submodules** under `lib/reach/otp/` (gen_server, gen_statem, dead_reply, cross_process, coupling). Cross-process analysis precomputes shared data — reuse the precomputed structures rather than re-traversing (commit `2f8b912`).
- **`lib/reach/cli/`** contains task-shared formatting (text/json/oneline, boxart wrappers, project loading). Mix tasks under `lib/mix/tasks/` should stay thin and delegate here.
- **Visualization** (`lib/reach/visualize/`, `priv/template.html.eex`, `assets/js/`) has hard correctness invariants — the 13 numbered Block Quality rules in `AGENTS.md`. Run `mix test test/visualize/block_quality_test.exs` after any change there.

## Conventions worth knowing

- `mix ci` is the contract. CI failures usually trace to one of: `--warnings-as-errors`, `ex_dna` clones, or dialyzer. `ex_dna` failing means real duplication — extract, don't suppress.
- Optional-dep code paths must work with the dep absent. Guard with `Code.ensure_loaded?/1` and feature-flag the public function (see `:volt` config and `:boxart` graph rendering for the pattern).
- Multi-clause functions use `build_multi_clause_cfg`; pure pattern dispatches (≤2 children per clause) take the single-function path. Do not filter clause nodes out of the CFG for multi-clause defs — see `AGENTS.md` "What NOT to Do".
- Source spans come from the parser/compiler. Never reconstruct construct boundaries by string matching the source — always use the IR/AST.
- The frontend (`assets/js/components/ReachGraph.vue`) uses Vue Flow + ELK for layout. JS/TS lint config: `assets/oxlint.json`, `assets/.oxfmtrc.json`, driven by `mix js.check`.

## Things this repo does NOT have

- No `.github/workflows/` content, no `.cursorrules`, no `.github/copilot-instructions.md` — `mix ci` is the only pipeline definition.
- No database, no Phoenix endpoint, no runtime supervision tree beyond the standard `:logger`. Pure library + Mix tasks.
