import type { GraphData } from "./types"

interface ElkNode {
  id: string
  width: number
  height: number
  labels?: { text: string }[]
}

interface ElkEdge {
  id: string
  sources: string[]
  targets: string[]
}

interface ElkGraph {
  id: string
  layoutOptions: Record<string, string>
  children: ElkNode[]
  edges: ElkEdge[]
}

interface ElkResult {
  children?: { id: string; x?: number; y?: number }[]
}

declare global {
  interface Window {
    ELK: new () => { layout: (graph: ElkGraph) => Promise<ElkResult> }
  }
}

export async function computeLayout(
  nodeIds: string[],
  nodeSizes: Map<string, { width: number; height: number }>,
  edges: { source: string; target: string; id: string }[]
): Promise<Map<string, { x: number; y: number }>> {
  const elk = new window.ELK()

  const children: ElkNode[] = nodeIds.map((id) => {
    const size = nodeSizes.get(id) ?? { width: 200, height: 60 }
    return { id, width: size.width, height: size.height }
  })

  const elkEdges: ElkEdge[] = edges.map((e) => ({
    id: e.id,
    sources: [e.source],
    targets: [e.target]
  }))

  const graph: ElkGraph = {
    id: "root",
    layoutOptions: {
      "elk.algorithm": "layered",
      "elk.direction": "DOWN",
      "elk.layered.spacing.nodeNodeBetweenLayers": "60",
      "elk.spacing.nodeNode": "30",
      "elk.layered.crossingMinimization.strategy": "LAYER_SWEEP",
      "elk.layered.nodePlacement.strategy": "NETWORK_SIMPLEX",
      "elk.edgeRouting": "ORTHOGONAL"
    },
    children,
    edges: elkEdges
  }

  const result = await elk.layout(graph)
  const positions = new Map<string, { x: number; y: number }>()

  for (const child of result.children ?? []) {
    positions.set(child.id, { x: child.x ?? 0, y: child.y ?? 0 })
  }

  return positions
}
