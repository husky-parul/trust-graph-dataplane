# Skill: Build a lightweight Trust DAG + Causality UI for Agent Ops

## Goal
Design a minimal, ops-friendly UI that turns distributed tracing telemetry into an explorable Trust DAG and provides fast answers to:
- Who acted on behalf of whom
- Why a downstream resource was accessed
- Whether behavior is novel, drifting, or retrying

The UI must stay lightweight, avoid dashboards, and prioritize “answer in 30 seconds” workflows.

---

## Core Concepts
- **Run**: a single end-to-end agent execution, identified by `run_id`
- **Trust DAG**: a causal graph derived from telemetry
  - Nodes: `principal`, `agent`, `resource`
  - Edges: `principal_to_agent`, `agent_to_agent`, `agent_to_resource`
- **Explain**: a causal justification for why a node (usually a resource) was accessed
- **Novelty**: edges or paths not seen in baseline history
- **Retries**: repeated calls on the same edge within a short time window

---

## Data Contracts

### 1) Trust DAG endpoint
**GET** `/lineage/{run_id}/trust`

Returns:
- `run_id`, `principal`
- `nodes[]`: `{ id, type, label }`
- `edges[]`: `{ source, target, hop_kind, count, span_ids[], first_ts, last_ts, total_duration_us }`
- `summary`: `{ total_nodes, total_edges, principals, agents, resources }`

### 2) Explain endpoint
**GET** `/lineage/{run_id}/explain?node={node_id}`

Returns:
- `question`, `target`, `target_type`, `run_id`, `principal`
- `direct_accessors[]`
- `access_chains[]` including:
  - `accessor`, `hop_kind`, `call_count`, `first_ts`, `last_ts`, `duration_us`
  - `delegated_by[]`: ordered chain of `{ actor, hop_kind, first_ts }`
- `parallel_groups[]`
- `all_paths_to_principal[]`
- `answer` (pre-rendered summary string)

### 3) Assessment endpoint (optional but recommended)
**GET** `/lineage/{run_id}/assess`

Returns:
- `risk_score`
- `verdict`
- `findings[]` including novelty signals:
  - `novel_edge`
  - `novel_path`
  - baseline counts like `seen_in_prior_runs`

If no assessment endpoint exists, compute basic novelty client-side using stored baselines.

---

## UI Layout

### Top Bar (always visible)
- Run selector: `run_id` (paste + search)
- Key badges: `principal`, `risk_score` (if available), `findings`
- Baseline indicator: `N prior runs` (if available)

### Main Panel (Graph-first)
- Interactive DAG canvas
  - pan + zoom
  - hover tooltips
  - click node/edge selection

### Right Drawer (Explain-first)
Tabs:
1. **Explain (node)**: why this node was accessed, delegated-by chain, parallel groups
2. **Edge detail**: count, timestamps, retry hint, span IDs, links out to tracing UI
3. **Paths**: all paths to principal, with “spotlight path” toggle

Optional bottom strip:
- Compact timeline of key edge events (first/last timestamps only)

---

## Visual Encoding Rules

### Node styling
- Principal: blue, ellipse
- Agent: green, rounded rectangle
- Resource: orange, cylinder

### Edge styling
- Color by `hop_kind`
- Thickness by `count`
- Label: show `xN` when `count > 1`

### Novelty styling
- **Novel edge**: subtle glow outline
- **Novel path**: “spotlight mode” dims non-path edges to ~20% opacity

### Retry styling
- Retry is not a separate edge. It is multiplicity + timing.
- If `count > 1` and spans are clustered in time, show a small `↻` hint next to `xN`
- Edge detail tab must show individual span IDs and timestamps

---

## Interaction Model

### Run selection
1. User selects or pastes `run_id`
2. UI fetches `/trust`
3. UI preselects the most “interesting” node:
   - resource nodes first (if any)
   - otherwise the entry agent

### Node click
- Opens Explain tab with `/explain?node={node_id}`
- Highlights all inbound and outbound edges for that node
- Provides “Spotlight paths to principal” toggle

### Edge click
- Opens Edge detail tab
- Shows:
  - `count`, `first_ts`, `last_ts`, `total_duration_us`
  - `span_ids`
  - retry hint if applicable
- Offers “Open trace” and “Open span” deep-links (configurable URL templates)

### Spotlight mode
- User toggles “Show novel paths” or “Spotlight to principal”
- Graph dims non-selected edges
- Right drawer shows paths list with quick-select

---

## Ops-first Defaults
- Default screen must answer: “Why was this resource accessed?”
- Default selection: first resource node if present
- Avoid advanced filters by default
- Always show:
  - principal
  - direct accessors
  - delegated-by chain
  - call counts

---

## Baseline and Storage Guidance
This UI works in two modes:

### Mode A: trace-only (no durable store)
- Uses only the selected `run_id`
- Novelty features limited unless a client-side cache exists

### Mode B: canonical lineage store (recommended)
- Store Trust DAG and assessment outputs in SQLite (or equivalent)
- Baseline computed from prior runs:
  - edge frequency
  - path frequency
  - typical fan-out and depth

In Mode B, the UI must display “seen in X of Y prior runs” for novelty findings.

---

## Acceptance Tests

### A) Core UI
- Given a valid `run_id`, the graph renders within 2 seconds
- Nodes are typed correctly (principal, agent, resource)
- Edge thickness and `xN` labels match `count`

### B) Explain correctness
- Clicking `resource:*` displays:
  - direct accessors
  - delegation chains back to the principal
  - parallel groups if present
- “Answer” string is shown verbatim, with a “Copy JSON” button

### C) Retry representation
- For an edge with `count > 1`, UI shows `xN`
- Edge detail lists all span IDs for that edge
- Retry hint appears only when calls are time-clustered

### D) Novelty representation
- If assessment includes `novel_edge` or `novel_path`, the UI highlights them
- Spotlight mode correctly dims non-path edges

### E) Trace escape hatch
- From edge detail, “Open trace” uses a configured URL template
- Links open the external tracing UI to the relevant trace/span context

---

## Implementation Notes
- Keep the UI single-page and fast
- Use a lightweight graph library capable of pan/zoom and click events
- Prefer server-side computation for:
  - explain
  - baseline novelty
  - assessment
- Keep payloads small by default, with “expand evidence” on demand

---

## Demo Script (10 minutes)
1. Show a trace view and ask: who caused db access
2. Paste `run_id` into the UI
3. Click `resource:mock-database` and show Explain output
4. Click the `read → db x2` edge to show retry evidence
5. Toggle “novel paths” on an unknown principal run
6. Use “Open trace” once, then return to graph view
