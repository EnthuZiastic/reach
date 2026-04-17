<script setup>
import { Handle, Position } from "@vue-flow/core"

const props = defineProps({
  data: { type: Object, required: true },
})

const TYPE_COLORS = {
  function: { header: "#16a34a", headerText: "#fff", border: "#22c55e" },
  entry: { header: "#16a34a", headerText: "#fff", border: "#22c55e" },
  exit: { header: "#6b7280", headerText: "#fff", border: "#9ca3af" },
  expression: { header: "#475569", headerText: "#fff", border: "#64748b" },
  branch: { header: "#ea580c", headerText: "#fff", border: "#f97316" },
  assignment: { header: "#2563eb", headerText: "#fff", border: "#3b82f6" },
  pipe: { header: "#7c3aed", headerText: "#fff", border: "#8b5cf6" },
  clause: { header: "#2563eb", headerText: "#fff", border: "#3b82f6" },
  dispatch: { header: "#0891b2", headerText: "#fff", border: "#06b6d4" },
  match: { header: "#16a34a", headerText: "#fff", border: "#22c55e" },
  module: { header: "#7c3aed", headerText: "#fff", border: "#8b5cf6" },
  external: { header: "#6b7280", headerText: "#fff", border: "#9ca3af" },
  call: { header: "#7c3aed", headerText: "#fff", border: "#8b5cf6" },
  data: { header: "#0891b2", headerText: "#fff", border: "#06b6d4" },
  compact: { header: "#7c3aed", headerText: "#fff", border: "#8b5cf6" },
}

const colors = TYPE_COLORS[props.data.nodeType] ?? TYPE_COLORS.expression
const lines = props.data.sourceHtml
  ? props.data.sourceHtml.split("\n")
  : props.data.sourceText
    ? props.data.sourceText.split("\n")
    : props.data.lines || []
const showLabel = props.data.label && props.data.nodeType !== "expression"
</script>

<template>
  <div class="code-node" :style="{ borderColor: colors.border }">
    <Handle type="target" :position="Position.Top" />
    <div v-if="showLabel" class="code-node-header" :style="{ background: colors.header, color: colors.headerText }">
      {{ data.label }}
    </div>
    <div v-if="lines.length" class="code-node-body highlight">
      <table class="code-table">
        <tr v-for="(line, i) in lines" :key="i">
          <td class="line-number">{{ data.startLine + i }}</td>
          <td class="line-code" v-html="line"></td>
        </tr>
      </table>
    </div>
    <Handle type="source" :position="Position.Bottom" />
  </div>
</template>
