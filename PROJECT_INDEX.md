# Project Index: Reach

Generated: 2026-04-30

Program Dependence Graph (PDG) library for Elixir, Erlang, Gleam, JavaScript/TypeScript, and BEAM bytecode. Pure Elixir library + Mix tasks + a static interactive HTML/Vue report. Hex package `:reach` v1.8.0. Source: https://github.com/elixir-vibe/reach.

## Project Structure

```
reach/
├── lib/
│   ├── reach.ex                  # Public API (slicing, taint, queries)
│   ├── reach/
│   │   ├── ir.ex, ir/            # Reach.IR.Node + helpers
│   │   ├── frontend/             # 5 source frontends → IR
│   │   ├── control_flow.ex       # IR → CFG
│   │   ├── dominator.ex          # idom/postdom/DF
│   │   ├── control_dependence.ex
│   │   ├── data_dependence.ex    # def-use chains
│   │   ├── program_dependence    # (in system_dependence.ex tree)
│   │   ├── system_dependence.ex  # SDG = PDGs + call/summary edges
│   │   ├── call_graph.ex
│   │   ├── concurrency.ex, effects.ex, higher_order.ex
│   │   ├── otp.ex, otp/          # GenServer/GenStatem/coupling
│   │   ├── plugin.ex, plugins/   # Phoenix/Ecto/Oban/Ash/Jido/etc.
│   │   ├── cli/                  # task-shared format/boxart/project
│   │   ├── visualize.ex, visualize/
│   │   ├── graph.ex, project.ex
│   └── mix/tasks/                # 18 tasks: reach.* + js.check
├── test/                         # 31 test files
├── assets/js/components/         # CodeNode.vue, CompactNode.vue, ReachGraph.vue
├── priv/template.html.eex        # HTML report template
├── AGENTS.md                     # Block Quality invariants + task reference
├── CHANGELOG.md, README.md, CLAUDE.md
├── mix.exs, mix.lock, .tool-versions, .formatter.exs
└── config/
```

## Pipeline

```
Source (.ex/.erl/.gleam/.js/.ts/.beam)
  → Reach.Frontend.*  → IR (Reach.IR.Node)
  → Reach.ControlFlow → CFG
  → Reach.Dominator + Reach.ControlDependence + Reach.DataDependence
  → Reach.ProgramDependence  → PDG
  → Reach.SystemDependence   → SDG (+ OTP + plugin edges)
  → Queries: backward_slice, forward_slice, taint_analysis, independent?
```

## Entry Points

- **Library API**: `lib/reach.ex` — `string_to_graph!/1`, `nodes/2`, `backward_slice/2`, `forward_slice/2`, `taint_analysis/2`, `independent?/3`, `dead_code/1`.
- **Mix tasks**: `lib/mix/tasks/reach.ex` (interactive HTML) + 17 analysis tasks.
- **HTML report**: `priv/template.html.eex` rendered with bundle from `priv/static/reach.{js,css}` (built by `mix assets.build` via `:volt`).

## Core Modules (lib/reach/)

| Module | Path | Purpose |
|---|---|---|
| `Reach` | `lib/reach.ex` | Public API surface |
| `Reach.IR` / `IR.Node` / `IR.Helpers` / `IR.Counter` | `lib/reach/ir*.ex` | Common IR shape across frontends |
| `Reach.Frontend.Elixir` | `lib/reach/frontend/elixir.ex` | AST → IR |
| `Reach.Frontend.Erlang` | `lib/reach/frontend/erlang.ex` | Erlang abstract code → IR |
| `Reach.Frontend.Gleam` | `lib/reach/frontend/gleam.ex` | Gleam → IR |
| `Reach.Frontend.JavaScript` | `lib/reach/frontend/javascript.ex` | JS/TS → IR |
| `Reach.Frontend.BEAM` | `lib/reach/frontend/beam.ex` | BEAM bytecode → IR (post macro-expansion) |
| `Reach.ControlFlow` | `lib/reach/control_flow.ex` | Per-function DAG |
| `Reach.Dominator` | `lib/reach/dominator.ex` | idom/postdom/dom-tree/DF |
| `Reach.ControlDependence` | `lib/reach/control_dependence.ex` | |
| `Reach.DataDependence` | `lib/reach/data_dependence.ex` | def-use chains |
| `Reach.SystemDependence` | `lib/reach/system_dependence.ex` | SDG construction |
| `Reach.CallGraph` | `lib/reach/call_graph.ex` | |
| `Reach.Effects` | `lib/reach/effects.ex` | Effect classification (pure/io/read/write/send/exception/nif/unknown) |
| `Reach.Concurrency` | `lib/reach/concurrency.ex` | spawn/Task/monitor/supervisor patterns |
| `Reach.HigherOrder` | `lib/reach/higher_order.ex` | |
| `Reach.OTP` (+ `otp/coupling`, `cross_process`, `dead_reply`, `gen_server`, `gen_statem`) | `lib/reach/otp*.ex` | OTP-shape analyses |
| `Reach.Plugin` | `lib/reach/plugin.ex` | Plugin contract |
| Plugins | `lib/reach/plugins/*.ex` | ash, ecto, gen_stage, helpers, jido, json, oban, open_telemetry, phoenix, quickbeam |
| `Reach.CLI.Format` / `BoxartGraph` / `Project` | `lib/reach/cli/*.ex` | Task-shared formatting + project loading |
| `Reach.Visualize` (+ `visualize/control_flow`, `visualize/helpers`) | `lib/reach/visualize*.ex` | CFG → blocks/edges for HTML |
| `Reach.Graph`, `Reach.Project` | `lib/reach/{graph,project}.ex` | Graph wrapper + project loader |

## Mix Tasks (lib/mix/tasks/)

All analysis tasks support `--format text|json|oneline`; many accept `--graph` (requires `:boxart`).

| Task | File | Purpose |
|---|---|---|
| `mix reach` | `reach.ex` | Interactive HTML report (CFG, call graph, data flow) |
| `mix reach.modules` | `reach.modules.ex` | Module listing + complexity |
| `mix reach.coupling` | `reach.coupling.ex` | Afferent/efferent/instability/circular deps |
| `mix reach.hotspots` | `reach.hotspots.ex` | complexity × callers |
| `mix reach.depth` | `reach.depth.ex` | Dominator-tree depth |
| `mix reach.effects` | `reach.effects.ex` | Effect distribution |
| `mix reach.impact` | `reach.impact.ex` | Change impact for a function |
| `mix reach.deps` | `reach.deps.ex` | Function deps + shared state |
| `mix reach.dead_code` | `reach.dead_code.ex` | Unused pure expressions |
| `mix reach.smell` | `reach.smell.ex` | Pipeline waste, redundant computation |
| `mix reach.flow` | `reach.flow.ex` | Data flow / taint (`--from/--to/--variable`) |
| `mix reach.slice` | `reach.slice.ex` | Backward/forward slice from a line |
| `mix reach.graph` | `reach.graph.ex` | Terminal CFG (boxart) |
| `mix reach.xref` | `reach.xref.ex` | Cross-function data flow |
| `mix reach.concurrency` | `reach.concurrency.ex` | Task/monitor/spawn + supervisor topology |
| `mix reach.boundaries` | `reach.boundaries.ex` | Multi-effect functions |
| `mix reach.otp` | `reach.otp.ex` | GenServer SM, ETS/proc-dict coupling, missing handlers |
| `mix js.check` | `js.check.ex` | Frontend lint/format gate |

## Configuration

- `mix.exs` — package, deps, aliases (`ci`, `assets.build`), dialyzer PLT path, ex_doc groups.
- `.tool-versions` — `elixir 1.19.5-otp-27`.
- `.formatter.exs` — formats `{config,lib,test}/**/*.{ex,exs}`.
- `.credo.exs` — Credo strict config.
- `assets/oxlint.json`, `assets/.oxfmtrc.json` — JS lint/format (oxlint + oxfmt) driven by `mix js.check`.
- `assets/package.json` — JS deps for the report (Vue Flow + ELK layout).

## Documentation

- `README.md` — Quick start, slicing/taint/independence/dead-code workflows, CLI overview.
- `AGENTS.md` — **authoritative** Block Quality Acceptance Criteria (13 numbered invariants) + Multi-clause function rules + per-task CLI table. Read before editing `lib/reach/visualize/` or `assets/js/`.
- `CHANGELOG.md` — Release history.
- `CLAUDE.md` — Repo-level Claude Code guidance.
- `LICENSE` — MIT.

## Test Coverage

31 `*.exs` files under `test/`:

- **Frontends**: `frontend/{elixir,erlang,javascript,beam}_test.exs`, `frontend/beam_source_span_test.exs`, `ir/frontend_elixir_test.exs`.
- **IR**: `ir/ir_property_test.exs` (StreamData property tests).
- **Analyses**: `control_flow/control_flow_test.exs`, `control_dependence_test.exs`, `data_dependence_test.exs`, `dominator_test.exs`, `system_dependence_test.exs`, `call_graph_test.exs`, `concurrency_test.exs`, `effects_test.exs`, `query_test.exs`, `smell_test.exs`, `otp_test.exs`, `reach_test.exs`, `project_test.exs`.
- **Plugins**: `plugins_test.exs`, `ash_plugin_test.exs`, `jido_plugin_test.exs`, `otel_plugin_test.exs`, `quickbeam_plugin_test.exs`.
- **Mix tasks**: `mix_task_{reach,modules,impact,slice}_test.exs`.
- **Visualization invariants**: `visualize_test.exs`, `visualize/block_quality_test.exs` (run after any `lib/reach/visualize/` change).

## Key Dependencies (mix.exs)

| Dep | Version | Role |
|---|---|---|
| `libgraph` | `~> 0.16.0` | Graph data structure (required) |
| `stream_data` | `~> 1.0` | Property tests (test/dev) |
| `dialyxir` | `~> 1.4` | Dialyzer (dev/test, no runtime) |
| `credo` | `~> 1.7` | Lint (dev/test, no runtime) |
| `jason` | `~> 1.0` | Optional — JSON output |
| `boxart` | `~> 0.3` | Optional — terminal graph rendering |
| `makeup`, `makeup_elixir`, `makeup_js` | `~> 1.0` / `~> 0.1` | Optional — syntax highlighting in HTML |
| `volt` | `~> 0.4` | Asset bundler (dev only) |
| `ex_doc` | `~> 0.34` | Docs (dev only) |
| `quickbeam` | `~> 0.10` | Optional plugin |
| `ex_ast` | `~> 0.1` | dev/test |
| `ex_dna` | `~> 1.1` | Clone detection in `mix ci` |

Optional deps must be guarded with `Code.ensure_loaded?/1`.

## Quick Start

```bash
mix deps.get
mix compile
mix ci             # compile-warnings → format --check → js.check → credo --strict → ex_dna → dialyzer → test
mix test test/visualize/block_quality_test.exs   # run after any visualize change
mix assets.build   # rebuild priv/static/reach.{js,css}
mix reach <path>   # interactive HTML report on a project
```

```elixir
graph = Reach.string_to_graph!("def run(x), do: System.cmd(\"sh\", [\"-c\", x])")
[c] = Reach.nodes(graph, type: :call, module: System, function: :cmd)
Reach.backward_slice(graph, c.id)
```

## Cross-cutting Conventions

- `mix ci` is the contract — never bypass with `--no-verify`.
- Optional-dep code paths must work with the dep absent (`Code.ensure_loaded?/1`).
- Multi-clause defs use `build_multi_clause_cfg`; pure pattern dispatches (≤2 children/clause) use single-function path. Do **not** filter clause nodes out for multi-clause defs.
- Source spans come from the parser/compiler — never reconstruct via string-matching the source.
- Frontends share IR contract; do not special-case downstream passes for new node types.
- Plugins attach edges *after* SDG is built and **must not** mutate IR/CFG.
