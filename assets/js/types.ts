export interface SourceSpan {
  file: string
  start_line: number
  start_col: number
}

export interface BlockData {
  id: string
  lines: string[]
  start_line: number
  source_html: string | null
}

export interface FunctionNode {
  id: string
  name: string
  arity: number
  module: string | null
  file: string | null
  blocks: BlockData[]
}

export interface GraphEdge {
  id: string
  source: string
  target: string
  edge_type: string
  color: string
}

export interface GraphData {
  file: string | null
  module: string | null
  functions: FunctionNode[]
  edges: GraphEdge[]
}
