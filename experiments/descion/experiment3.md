# Experiment 3: Trust DAG, Provenance Explain, and Temporal Ordering

## Goal

Transform raw distributed traces into structured trust artifacts that answer three questions:

1. **What happened?** — A Trust DAG with typed nodes and weighted edges
2. **Why was X accessed?** — Per-span provenance explanation with attribution to specific delegation paths
3. **In what order?** — A topologically ordered event list showing all causal hops, including duplicated edges from different delegation paths

All derived from Jaeger spans without application code instrumentation.

---

## Architecture

### The Problem

Experiment 2 established multi-agent trust lineage: a principal calls chat-agent, which fans out to sales-agent, read-agent, and summary-agent. Summary-agent in turn calls read-agent. The raw `/lineage/{run_id}` debug view shows all 13 spans chronologically — but it's a flat list. No structure. No causality. No "why."

### The Constraint: Independent Traces

Envoy sidecars create **independent traces** per listener. There are no parent-child span references across services. All spans are roots (`parent=ROOT`), correlated only via `trust.run_id`. This means standard trace-tree reconstruction doesn't work. We needed a different approach.

### The Solution: Temporal Backtracking

Instead of following parent span references, we reconstruct causal chains by **temporal ordering**:

> For each span, find the most recent inbound span with `trust.target = current_actor` that started before the current span's timestamp.

This tells us "who called this agent just before it made this downstream call." Walking backwards from any span to the principal reconstructs the full delegation chain for that specific request.

The `reconstruct_causal_chain()` function implements this:

```
Input:  A target span (e.g., read-agent -> mock-database at T=100)
Output: [user:claude -> chat-agent (T=10), chat-agent -> read-agent (T=50), read-agent -> mock-database (T=100)]
```

For the same edge `read-agent -> mock-database` at a later time T=200, temporal backtracking finds a *different* parent chain (via summary-agent), correctly attributing it to the summary delegation path.

---

## Three Endpoints

### 1. Trust DAG — `/lineage/{run_id}/dag`

A directed acyclic graph with typed nodes and weighted edges.

**Nodes** have:
- `id`: prefixed identifier (e.g., `user:claude`, `agent:chat-agent`, `resource:mock-database`)
- `type`: `principal | agent | resource`
- `label`: human-readable name

**Edges** have:
- `source`, `target`, `hop_kind`
- `count`: raw span observation count (includes duplicates from ingress + sidecar)
- `logical_count`: deduplicated span count (`len(span_ids)`)
- `span_ids`: list of unique span IDs that contributed to this edge
- `first_ts`, `last_ts`: timestamp window (microseconds)
- `total_duration_us`: sum of all span durations on this edge

**Field descriptions** are included in every response explaining what `count` vs `logical_count` means.

**Formats**: `?format=json` (default) and `?format=dot` (Graphviz). The DOT output uses `logical_count` for edge labels and colors nodes by type (blue=principal, green=agent, orange=resource).

**Example DAG for a multi-agent run:**

```
user:claude ──[principal_to_agent]──> agent:chat-agent
    ├──[agent_to_agent]──> agent:sales-agent ──[agent_to_resource]──> resource:mock-database
    ├──[agent_to_agent]──> agent:read-agent ──[agent_to_resource(x2)]──> resource:mock-database
    └──[agent_to_agent]──> agent:summary-agent ──[agent_to_agent]──> agent:read-agent
```

The `(x2)` on `read-agent -> mock-database` reflects `logical_count=2`: two distinct spans, one from the direct path and one from the summary path.

### 2. Provenance Explain — `/lineage/{run_id}/explain?node=...`

Answers: **"Why was this node accessed?"** with per-span attribution.

**Key design**: Each cause group represents a distinct delegation path traced from an individual span back to the principal via temporal backtracking. This means:

- Two paths through the same agent (e.g., read-agent accessed directly by chat-agent AND read-agent accessed via summary-agent) produce **separate cause groups** with **separate span counts and span_ids**
- No double-counting: each DB span is attributed to exactly one upstream chain

**Cause group fields**:
- `accessor`: the agent that directly accessed the target
- `hop_kind`: type of the final hop
- `span_count`: number of individual spans attributed to this specific path
- `span_ids`: actual span IDs for the access events on this path
- `first_ts`, `last_ts`, `total_duration_us`: per-path timing
- `full_path`: complete delegation chain from principal to target
- `delegated_by`: upstream actors in closest-first order (immediate caller first, principal last)

**Parallel execution detection**: Cause groups starting within 100ms of each other are flagged as concurrent. Uses `cause_indices` and distinct paths (not duplicated accessor names).

**Capability alignment** (future): The explain output provides the `full_path` and `accessor` needed to check whether each agent's observed behavior matches its declared capabilities.

**Example output for `?node=resource:mock-database`:**

```
Cause 1: user:claude -> agent:chat-agent -> agent:sales-agent -> resource:mock-database
         accessor=agent:sales-agent, spans=1, duration=2473us
         delegated_by: agent:chat-agent <- user:claude

Cause 2: user:claude -> agent:chat-agent -> agent:read-agent -> resource:mock-database
         accessor=agent:read-agent, spans=1, duration=1988us
         delegated_by: agent:chat-agent <- user:claude

Cause 3: user:claude -> agent:chat-agent -> agent:summary-agent -> agent:read-agent -> resource:mock-database
         accessor=agent:read-agent, spans=1, duration=3530us
         delegated_by: agent:summary-agent <- agent:chat-agent <- user:claude
```

Three distinct causes, three distinct spans, three distinct delegation chains.

### 3. Trust Chain — `/lineage/{run_id}/trust`

A **topologically ordered event list** — all causal hops in temporal order, including duplicated edges from different delegation paths.

This is NOT a deduplicated summary. It shows every unique hop in the context of its full delegation chain. The same `(source, target)` pair can appear multiple times if it was triggered by different upstream chains.

**Event fields**:
- `step`: ordinal position in temporal order
- `source`, `target`, `hop_kind`
- `span_duration_us`: duration of this individual span (not aggregated)
- `causal_path`: full delegation chain from principal to this hop's target

**Deduplication logic**: Events are keyed by `(source, target, full_causal_path)`. This removes ingress/sidecar doubles (same hop, same context) while preserving distinct paths (same hop, different upstream context).

**Example — 8 events for a multi-agent run:**

```
1. [principal_to_agent] user:claude -> agent:chat-agent
2. [agent_to_agent]     agent:chat-agent -> agent:sales-agent
3. [agent_to_resource]  agent:sales-agent -> resource:mock-database
4. [agent_to_agent]     agent:chat-agent -> agent:read-agent
5. [agent_to_resource]  agent:read-agent -> resource:mock-database       (via: claude -> chat -> read -> db)
6. [agent_to_agent]     agent:chat-agent -> agent:summary-agent
7. [agent_to_agent]     agent:summary-agent -> agent:read-agent
8. [agent_to_resource]  agent:read-agent -> resource:mock-database       (via: claude -> chat -> summary -> read -> db)
```

Steps 5 and 8 are both `read-agent -> mock-database` but with different causal paths. The old deduplicated view (pre-fix) would have shown only one, losing the summary-agent delegation context.

---

## Correctness Fixes

Three correctness issues were identified after the initial implementation and fixed:

### Fix 1: DAG `count` vs `logical_count`

**Problem**: `count=2` for `user:claude -> agent:chat-agent` but only 1 `span_id`. The semantics were conflated — `count` was raw observations (ingress + sidecar = 2 spans for 1 logical hop), but `span_ids` was deduplicated.

**Fix**: Added `logical_count = len(span_ids)` as a separate field. Kept `count` as raw observations. Added `field_descriptions` to every DAG response explaining both semantics.

### Fix 2: Explain endpoint double-counting

**Problem**: Two cause groups for `read-agent -> mock-database` shared identical `call_count`, `first_ts`, `last_ts`, and `duration_us` — because both read from the same shared DAG edge instead of attributing individual spans to their specific upstream chains.

**Fix**: Replaced DAG-level edge sharing with per-span temporal backtracking. Each DB span is now traced back through its individual causal chain using `reconstruct_causal_chain()`. Result: each cause group has its own `span_count`, `span_ids`, and timing derived from the actual spans attributed to that specific path. Also fixed `parallel_groups` to use `cause_indices` and distinct paths instead of duplicated accessor names.

### Fix 3: Trust chain missing hops

**Problem**: The trust chain was a deduplicated linear list keyed by `(source, target)`. This collapsed the two distinct `read-agent -> mock-database` hops into one, losing the summary-agent delegation context. Also, duration semantics were inconsistent (individual span vs aggregated).

**Fix**: Changed to a topologically ordered event list keyed by `(source, target, full_causal_path)`. All causal hops appear, including duplicated edges from different paths. Each event shows `span_duration_us` (individual span duration, clearly labeled).

---

## Key Technical Decisions

| Decision | Rationale |
|----------|-----------|
| Temporal backtracking over parent refs | Envoy creates independent traces per listener; no cross-service parent-child refs exist |
| `logical_count` alongside `count` | Different audiences need different semantics; raw for debugging, deduplicated for analysis |
| Per-span attribution in explain | Shared edge counts are misleading when multiple paths traverse the same edge |
| Closest-first delegation order | Most useful for debugging: immediate caller first, root principal last |
| Full causal path as dedup key | Preserves distinct delegation contexts for the same (source, target) pair |
| 100ms window for parallel detection | Pragmatic threshold for "close enough" in our sequential sidecar system |

---

## Endpoints Summary

| Endpoint | Format | Description |
|----------|--------|-------------|
| `/lineage/{run_id}/dag?format=json` | JSON | DAG with nodes + edges, counts, timing |
| `/lineage/{run_id}/dag?format=dot` | Graphviz DOT | Visual graph with typed node colors |
| `/lineage/{run_id}/explain?node=...&format=json` | JSON | Per-span provenance with cause groups |
| `/lineage/{run_id}/explain?node=...&format=text` | Text | Human-readable provenance explanation |
| `/lineage/{run_id}/trust?format=json` | JSON | Topologically ordered event list |
| `/lineage/{run_id}/trust?format=text` | Text | Human-readable event list |

All existing endpoints (`/lineage/all`, `/lineage/{run_id}`) remain unchanged as debug/discovery views.

---

## Git History

```
deae0ad Experiment 3: Trust DAG with explain endpoint and temporal ordering
3a6c818 Fix explain endpoint: separate cause groups per delegation path
75316d4 Fix lineage endpoint correctness: per-span attribution and topological trust chain
```

Tags: `demo-dag`
