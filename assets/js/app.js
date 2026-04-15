import { Controls } from "@vue-flow/controls"
import { VueFlow, useVueFlow, Handle, Position } from "@vue-flow/core"
import { MiniMap } from "@vue-flow/minimap"
import { createApp, ref, onMounted, nextTick, computed, h } from "vue"
const TYPE_COLORS = {
  function: { header: "#16a34a", headerText: "#fff", border: "#22c55e" },
  clause: { header: "#2563eb", headerText: "#fff", border: "#3b82f6" },
  module: { header: "#7c3aed", headerText: "#fff", border: "#8b5cf6" },
  external: { header: "#6b7280", headerText: "#fff", border: "#9ca3af" }
}

const CodeNode = {
  props: { data: Object },
  setup(props) {
    const colors = TYPE_COLORS[props.data.nodeType] ?? TYPE_COLORS.clause

    return () =>
      h("div", { class: "code-node", style: { borderColor: colors.border } }, [
        h(Handle, { type: "target", position: Position.Top }),
        h(
          "div",
          {
            class: "code-node-header",
            style: { background: colors.header, color: colors.headerText }
          },
          props.data.label
        ),
        props.data.sourceHtml
          ? h("div", { class: "code-node-body highlight" }, [
              h(
                "table",
                { class: "code-table" },
                props.data.lines.map((line, i) =>
                  h("tr", { key: i }, [
                    h("td", { class: "line-number" }, props.data.startLine + i),
                    h("td", { class: "line-code", innerHTML: line })
                  ])
                )
              )
            ])
          : props.data.sourceText
            ? h("div", { class: "code-node-body highlight" }, [
                h(
                  "table",
                  { class: "code-table" },
                  props.data.sourceText
                    .split("\n")
                    .map((line, i) =>
                      h("tr", { key: i }, [
                        h("td", { class: "line-number" }, props.data.startLine + i),
                        h("td", { class: "line-code" }, [h("code", null, line)])
                      ])
                    )
                )
              ])
            : null,
        h(Handle, { type: "source", position: Position.Bottom })
      ])
  }
}
import { computeLayout } from "@reach/layout"

const EDGE_TYPES = {
  data: { color: "#16a34a", label: "Data flow" },
  control: { color: "#ea580c", label: "Control" },
  containment: { color: "#94a3b8", label: "Contains" },
  call: { color: "#7c3aed", label: "Call" },
  match_binding: { color: "#16a34a", label: "Match bind" },
  state_read: { color: "#0891b2", label: "State read" },
  state_pass: { color: "#0891b2", label: "State pass" },
  higher_order: { color: "#db2777", label: "Higher order" },
  message_order: { color: "#ca8a04", label: "Message" },
  summary: { color: "#7c3aed", label: "Summary" }
}

const ReachGraph = {
  props: { graphData: Object },
  setup(props) {
    const nodeTypes = { code: CodeNode }
    const nodes = ref([])
    const edges = ref([])
    const activeFilters = ref(new Set(Object.keys(EDGE_TYPES)))
    const { fitView } = useVueFlow()

    const filteredEdges = computed(() =>
      edges.value.filter((e) => {
        const type = e.data?.edgeType
        return activeFilters.value.has(type) || !EDGE_TYPES[type]
      })
    )

    function toggleFilter(type) {
      const s = new Set(activeFilters.value)
      if (s.has(type)) s.delete(type)
      else s.add(type)
      activeFilters.value = s
    }

    function edgeStyle(edgeType) {
      const color = EDGE_TYPES[edgeType]?.color ?? "#94a3b8"
      return { stroke: color, strokeWidth: edgeType === "containment" ? 1 : 2 }
    }

    async function buildGraph() {
      const data = props.graphData
      if (!data) return

      const rawNodes = []
      let rawEdges = []

      for (const fn of data.functions) {
        for (const block of fn.blocks) {
          const lines = block.source_html ? block.source_html.split("\n") : (block.lines ?? [])

          rawNodes.push({
            id: block.id,
            type: "code",
            position: { x: 0, y: 0 },
            data: {
              label: `${fn.name}/${fn.arity}`,
              nodeType: fn.module ? "function" : "external",
              sourceHtml: block.source_html,
              sourceText: block.source_html ? null : block.lines?.join("\n"),
              lines,
              startLine: block.start_line
            }
          })
        }
      }

      for (const e of data.edges) {
        rawEdges.push({
          id: e.id,
          source: e.source,
          target: e.target,
          type: e.edge_type === "containment" ? "straight" : "smoothstep",
          style: edgeStyle(e.edge_type),
          data: { edgeType: e.edge_type }
        })
      }

      const nodeIdSet = new Set(rawNodes.map((n) => n.id))
      rawEdges = rawEdges.filter((e) => nodeIdSet.has(e.source) && nodeIdSet.has(e.target))
      const nodeIds = rawNodes.map((n) => n.id)
      const nodeSizes = new Map()
      for (const n of rawNodes) {
        const lineCount = n.data.lines?.length ?? 1
        const maxLen = (n.data.lines ?? [n.data.label]).reduce((m, l) => Math.max(m, l.length), 0)
        nodeSizes.set(n.id, {
          width: Math.max(200, maxLen * 7.5 + 60),
          height: Math.max(50, lineCount * 18 + 30)
        })
      }

      const layoutEdges = rawEdges
        .filter((e) => e.data.edgeType !== "containment")
        .map((e) => ({ id: e.id, source: e.source, target: e.target }))

      const positions = await computeLayout(nodeIds, nodeSizes, layoutEdges)
      for (const n of rawNodes) {
        const pos = positions.get(n.id)
        if (pos) n.position = pos
      }

      nodes.value = rawNodes
      edges.value = rawEdges
      await nextTick()
      fitView({ padding: 0.15 })
    }

    onMounted(buildGraph)

    return () =>
      h("div", { class: "reach-container" }, [
        props.graphData?.file
          ? h("div", { class: "file-header" }, [
              h("span", { class: "file-path" }, props.graphData.file),
              props.graphData.module
                ? h("span", { class: "module-name" }, props.graphData.module)
                : null
            ])
          : null,
        h(
          VueFlow,
          {
            nodes: nodes.value,
            edges: filteredEdges.value,
            nodeTypes,
            defaultEdgeOptions: { type: "smoothstep" },
            minZoom: 0.1,
            maxZoom: 3,
            class: "reach-flow"
          },
          { default: () => [h(MiniMap, { pannable: true, zoomable: true }), h(Controls)] }
        ),
        h(
          "div",
          { class: "edge-filter" },
          Object.entries(EDGE_TYPES).map(([type, info]) =>
            h(
              "button",
              {
                class: ["filter-btn", activeFilters.value.has(type) ? "active" : ""],
                onClick: () => toggleFilter(type)
              },
              [
                h("span", { class: "filter-dot", style: { background: info.color } }),
                ` ${info.label}`
              ]
            )
          )
        )
      ])
  }
}

createApp(ReachGraph, { graphData: window.graphData }).mount("#app")
