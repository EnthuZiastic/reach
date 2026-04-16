<script setup>
import { ref, onMounted, nextTick, computed, watch } from "vue"
import { VueFlow, useVueFlow } from "@vue-flow/core"
import { MiniMap } from "@vue-flow/minimap"
import { Controls } from "@vue-flow/controls"
import CodeNode from "@reach/components/CodeNode.vue"
import CompactNode from "@reach/components/CompactNode.vue"
import { computeLayout } from "@reach/layout"

const props = defineProps({
  graphData: { type: Object, required: true },
})

const nodeTypes = { code: CodeNode, compact: CompactNode }
const mode = ref("control_flow")
const nodes = ref([])
const edges = ref([])
const selectedModule = ref(null)
const selectedFunction = ref(null)
const expandedFunction = ref(null)
const { fitView, setCenter } = useVueFlow()

async function applyLayout(rawNodes, rawEdges, layoutOverrides = {}) {
  const nodeIds = rawNodes.map((n) => n.id)
  const nodeSizes = new Map()
  for (const n of rawNodes) {
    nodeSizes.set(n.id, estimateSize(n.data))
  }

  const nodeIdSet = new Set(nodeIds)
  const validEdges = rawEdges.filter((e) => nodeIdSet.has(e.source) && nodeIdSet.has(e.target))

  const positions = await computeLayout(
    nodeIds,
    nodeSizes,
    validEdges.map((e) => ({ id: e.id, source: e.source, target: e.target })),
    layoutOverrides
  )

  for (const n of rawNodes) {
    const pos = positions.get(n.id)
    if (pos) n.position = pos
  }

  nodes.value = rawNodes
  edges.value = validEdges
  await nextTick()
  fitView({ padding: 0.1 })
}

function estimateSize(data) {
  if (data.nodeType === "compact") {
    const len = (data.label ?? "").length
    return { width: Math.max(100, len * 7.5 + 24), height: 32 }
  }

  const lineCount = (data.sourceHtml || "").split("\n").length || (data.lines?.length ?? 1)
  const labelLen = (data.label ?? "").length
  const maxCodeLen = Math.max(labelLen, ...(data.lines || []).map((l) => l.length))
  return {
    width: Math.min(700, Math.max(180, maxCodeLen * 7.5 + 70)),
    height: Math.max(36, lineCount * 18 + (data.label ? 26 : 8)),
  }
}

function makeCodeNode(id, label, nodeType, data) {
  return {
    id,
    type: "code",
    position: { x: 0, y: 0 },
    data: {
      label,
      nodeType,
      sourceHtml: data.source_html || data.sourceHtml,
      sourceText: data.source_text || data.sourceText || null,
      lines: data.source_html ? data.source_html.split("\n") : (data.lines || []),
      startLine: data.start_line || data.startLine || 1,
    },
  }
}

// ── Control Flow View ──

async function buildControlFlow() {
  const cf = props.graphData.control_flow
  if (!cf?.length) return

  const allNodes = []
  const allEdges = []

  for (const mod of cf) {
    for (const func of mod.functions) {
      if (!func.nodes?.length) continue

      // If this function is not expanded, show as a single collapsed node
      if (expandedFunction.value !== func.id) {
        const sourceHtml = func.nodes
          .map((n) => n.source_html)
          .filter(Boolean)
          .join("\n")

        allNodes.push(
          makeCodeNode(func.id, `${mod.module ? mod.module + "." : ""}${func.name}/${func.arity}`, "function", {
            source_html: sourceHtml,
            lines: func.nodes.flatMap((n) => n.lines || []),
            start_line: func.nodes[0]?.start_line,
          })
        )
        continue
      }

      // Expanded: show all expression nodes
      for (const node of func.nodes) {
        let label = node.label
        if (!label && node.type === "entry") {
          label = `${func.name}/${func.arity}`
        }

        const nodeType = visNodeType(node.type)
        allNodes.push(makeCodeNode(node.id, label, nodeType, node))
      }

      for (const edge of func.edges || []) {
        allEdges.push({
          id: edge.id,
          source: edge.source,
          target: edge.target,
          type: edgeStyle(edge.edge_type),
          style: edgeVisualStyle(edge),
          label: edge.label,
          labelStyle: {
            fill: edge.color,
            fontSize: 11,
            fontFamily: "ui-monospace, SFMono-Regular, monospace",
          },
          animated: edge.edge_type === "data",
        })
      }
    }
  }

  await applyLayout(allNodes, allEdges)
}

function visNodeType(type) {
  switch (type) {
    case "entry": return "function"
    case "exit": return "exit"
    case "branch": return "match"
    case "dispatch": return "clause"
    case "clause": return "clause"
    default: return "expression"
  }
}

function edgeStyle(edgeType) {
  switch (edgeType) {
    case "branch": return "smoothstep"
    case "converge": return "smoothstep"
    case "data": return "smoothstep"
    default: return "default"
  }
}

function edgeVisualStyle(edge) {
  const width = edge.edge_type === "sequential" ? 1 : 2
  return { stroke: edge.color, strokeWidth: width }
}

// ── Call Graph View ──

async function buildCallGraph() {
  const cg = props.graphData.call_graph
  if (!cg) return

  const rawNodes = []
  for (const mod of cg.modules) {
    for (const func of mod.functions) {
      const shortLabel = mod.file ? func.id.split(".").pop() : func.id
      rawNodes.push({
        id: func.id,
        type: "compact",
        position: { x: 0, y: 0 },
        data: { label: shortLabel, nodeType: "compact" },
      })
    }
  }

  const rawEdges = cg.edges.map((e) => ({
    id: e.id,
    source: e.source,
    target: e.target,
    type: "default",
    style: { stroke: e.color, strokeWidth: 1.5 },
  }))

  await applyLayout(rawNodes, rawEdges, {
    "elk.direction": "RIGHT",
    "elk.aspectRatio": "1.5",
    "elk.edgeRouting": "SPLINES",
  })
}

// ── Data Flow View ──

async function buildDataFlow() {
  const df = props.graphData.data_flow
  if (!df) return

  const rawNodes = df.functions.map((f) =>
    makeCodeNode(f.id, f.module ? `${f.module}.${f.label}` : f.label, "data", {
      source_html: f.source_html,
      lines: [],
      start_line: f.start_line,
    })
  )

  const rawEdges = df.edges.map((e) => ({
    id: e.id,
    source: e.source,
    target: e.target,
    type: "smoothstep",
    style: { stroke: e.color, strokeWidth: 2 },
    label: e.label,
    labelStyle: { fill: "#16a34a", fontSize: 11 },
  }))

  await applyLayout(rawNodes, rawEdges)
}

// ── Rebuild ──

async function rebuild() {
  try {
    switch (mode.value) {
      case "control_flow":
        await buildControlFlow()
        break
      case "call_graph":
        await buildCallGraph()
        break
      case "data_flow":
        await buildDataFlow()
        break
    }
  } catch (e) {
    console.error("rebuild error:", e)
  }
}

watch(mode, rebuild)
onMounted(rebuild)

// ── Sidebar ──

const sidebarModules = computed(() => {
  const cf = props.graphData.control_flow
  if (!cf) return []
  return cf.map((m) => ({
    name: m.module ?? "(top-level)",
    module: m.module,
    attributes: m.attributes || [],
    functions: m.functions.map((f) => ({
      id: f.id,
      label: `${f.name}/${f.arity}`,
    })),
  }))
})

function onNodeDoubleClick(event) {
  const clickedNode = event.node
  if (mode.value !== "control_flow") return

  // Check if this is a collapsed function — expand it
  const cf = props.graphData.control_flow
  for (const mod of cf) {
    const func = mod.functions.find((f) => f.id === clickedNode.id)
    if (func) {
      if (expandedFunction.value === func.id) {
        expandedFunction.value = null
      } else {
        expandedFunction.value = func.id
      }
      rebuild()
      return
    }
  }

  // Check if it's an entry node of an expanded function
  if (clickedNode.id?.endsWith("_entry")) {
    const funcId = clickedNode.id.replace("_entry", "")
    expandedFunction.value = expandedFunction.value === funcId ? null : funcId
    rebuild()
  }
}

function selectFunction(modName, funcId) {
  selectedModule.value = modName
  selectedFunction.value = funcId
  if (mode.value !== "control_flow") {
    mode.value = "control_flow"
  } else {
    expandedFunction.value = funcId
    rebuild()
  }
}
</script>

<template>
  <div class="reach-container">
    <div class="tab-bar">
      <div class="tab-bar-tabs">
        <button class="tab" :class="{ active: mode === 'control_flow' }" @click="mode = 'control_flow'">
          Control Flow
        </button>
        <button class="tab" :class="{ active: mode === 'call_graph' }" @click="mode = 'call_graph'">
          Call Graph
        </button>
        <button class="tab" :class="{ active: mode === 'data_flow' }" @click="mode = 'data_flow'">
          Data Flow
        </button>
      </div>
    </div>

    <div class="main-area">
      <div v-if="mode === 'control_flow'" class="sidebar">
        <div class="sidebar-title">Functions</div>
        <div v-for="mod in sidebarModules" :key="mod.name" class="sidebar-module">
          <div class="sidebar-module-name">{{ mod.name }}</div>
          <div v-if="mod.attributes.length" class="sidebar-attrs">
            <div v-for="attr in mod.attributes" :key="attr.name" class="sidebar-attr">
              <span class="attr-name">{{ attr.name }}</span>
              <span v-if="attr.value" class="attr-value"> = {{ attr.value }}</span>
            </div>
          </div>
          <button
            v-for="func in mod.functions"
            :key="func.id"
            class="sidebar-func"
            :class="{ active: selectedFunction === func.id }"
            @click="selectFunction(mod.module, func.id)"
          >
            {{ func.label }}
          </button>
        </div>
      </div>

      <VueFlow
        :nodes="nodes"
        :edges="edges"
        :node-types="nodeTypes"
        :default-edge-options="{ type: 'smoothstep' }"
        :min-zoom="0.1"
        :max-zoom="3"
        class="reach-flow"
        @node-double-click="onNodeDoubleClick"
      >
        <MiniMap pannable zoomable />
        <Controls />
      </VueFlow>
    </div>
  </div>
</template>
