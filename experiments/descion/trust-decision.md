# Experiment 4: Trust Graph Decision Surface

## Goal

Build a decision surface on top of the Trust Graph infrastructure. This is not enforcement — it is an observability and assessment layer that answers: **"Does this agent run look expected or suspicious?"**

The system provides observed provenance judgement with no SPIFFE, registry binding, or authorization assumptions. Every finding must reference concrete DAG edges, explain paths, or span IDs.

---

## Part 1: SQLite Canonical Lineage Store

### Why

The existing lineage endpoints re-query Jaeger on every request. This works but:

- **Retention**: Jaeger is short-lived; the decision surface needs weeks/months of history.
- **Performance**: Rebuilding graphs per-query doesn't scale once we add baseline/anomaly checks.
- **Baselines**: Need historical distributions (fanout, depth, novel edges). Can't do that reliably by re-querying Jaeger every time.

### Schema (5 tables)

```sql
runs(
  run_id          TEXT PRIMARY KEY,
  principal_id    TEXT,
  started_at      INTEGER,   -- earliest span timestamp (microseconds)
  ended_at        INTEGER,   -- latest span timestamp (microseconds)
  ingested_at     INTEGER,   -- when we wrote this to SQLite
  sealed          INTEGER DEFAULT 1,
  schema_version  INTEGER DEFAULT 1,
  content_hash    TEXT,      -- SHA256 of canonical representation
  node_count      INTEGER,
  edge_count      INTEGER,
  resource_count  INTEGER
)

nodes(
  run_id   TEXT,
  node_id  TEXT,
  type     TEXT,    -- principal | agent | resource
  label    TEXT,
  PRIMARY KEY(run_id, node_id)
)

edges(
  run_id            TEXT,
  source            TEXT,
  target            TEXT,
  hop_kind          TEXT,
  logical_count     INTEGER,  -- deduplicated span count
  raw_count         INTEGER,  -- raw span observation count
  first_ts          INTEGER,
  last_ts           INTEGER,
  total_duration_us INTEGER,
  PRIMARY KEY(run_id, source, target, hop_kind)
)

edge_spans(
  run_id   TEXT,
  source   TEXT,
  target   TEXT,
  hop_kind TEXT,
  span_id  TEXT,
  PRIMARY KEY(run_id, source, target, hop_kind, span_id)
)

paths(
  run_id      TEXT,
  target_node TEXT,
  full_path   TEXT,    -- JSON array e.g. '["user:claude","agent:chat-agent","agent:read-agent","resource:mock-database"]'
  accessor    TEXT,
  hop_kind    TEXT,
  span_count  INTEGER,
  PRIMARY KEY(run_id, full_path)
)
```

Design choice: runs are **append-only / sealed**. Once written, immutable.

### Persistence

SQLite file stored on a **PersistentVolumeClaim** so data survives pod restarts. Mounted into the lineage-service pod.

### Ingestion Flow (Lazy)

Ingestion happens **lazily on first query** to any lineage endpoint for a given run_id:

1. Check if `run_id` exists in `runs` table with `sealed=1`
2. If yes: serve from SQLite (fast path)
3. If no: fetch spans from Jaeger, compute DAG + explain + trust_chain, write to SQLite in one transaction, mark `sealed=1` with `content_hash`, then serve

This means:
- No separate ingest step or cron job
- First query for a run_id is slightly slower (Jaeger fetch + SQLite write)
- All subsequent queries are fast (SQLite read)
- Jaeger is only the raw source-of-truth; SQLite is the canonical derived store

### Existing Endpoint Migration

The existing endpoints change to **SQLite-first with Jaeger fallback**:

| Endpoint | Before | After |
|----------|--------|-------|
| `/lineage/{run_id}/dag` | Always queries Jaeger | Read from SQLite; fallback to Jaeger if not ingested |
| `/lineage/{run_id}/trust` | Always queries Jaeger | Read from SQLite; fallback to Jaeger if not ingested |
| `/lineage/{run_id}/explain` | Always queries Jaeger | Read from SQLite; fallback to Jaeger if not ingested |
| `/lineage/{run_id}/assess` | N/A (new) | Read from SQLite (triggers lazy ingest if needed) |
| `/lineage/{run_id}` | Always queries Jaeger | Unchanged (debug view, always Jaeger) |
| `/lineage/all` | Always queries Jaeger | Unchanged (discovery, always Jaeger) |

---

## Part 2: Agent Card Registration

### SQLite Table

```sql
agent_cards(
  agent_id        TEXT PRIMARY KEY,  -- e.g. "agent:read-agent"
  name            TEXT,
  version         TEXT,
  capabilities    TEXT,              -- JSON array
  endpoints       TEXT,              -- JSON object
  dependencies    TEXT,              -- JSON array of prefixed IDs e.g. ["resource:mock-database"]
  trust_metadata  TEXT,              -- JSON object
  registered_at   INTEGER,
  source          TEXT               -- "file" or "api"
)
```

### Agent Card Files

The existing agent card JSON files in `k8s/workloads/agent-cards/` will be updated to use **full prefixed node IDs** in their `dependencies` field. For example:

```json
{
  "name": "read-agent",
  "dependencies": ["resource:mock-database"]
}
```

Instead of bare names like `"mock-database"`.

### Two Registration Paths

**Path A — File auto-discovery on startup**:
- Create a ConfigMap from all agent card JSON files
- Mount into lineage-service pod at `/agent-cards/`
- On startup, the service scans the directory, parses each JSON, and upserts into `agent_cards` table
- Existing cards are always loaded without manual steps

**Path B — API for dynamic registration**:
- `POST /agent-cards` — accepts agent card JSON, stores in SQLite
- `GET /agent-cards` — lists all registered cards
- `GET /agent-cards/{agent_id}` — get one card
- Allows registering new agents at runtime without redeploying

---

## Part 3: Assessment Endpoint

### Endpoint

```
GET /lineage/{run_id}/assess?format=json|text
```

### Response Structure

```json
{
  "run_id": "...",
  "verdict": "ok | warn | high",
  "risk_score": 0-100,
  "baseline_runs": 42,
  "reasons": [
    {
      "rule": "novel_resource_access",
      "score": 20,
      "edge": {"source": "agent:read-agent", "target": "resource:secret-db"},
      "span_ids": ["abc123"],
      "detail": "agent:read-agent has never accessed resource:secret-db in 42 prior runs"
    }
  ],
  "novel_edges": [
    {"source": "...", "target": "...", "hop_kind": "..."}
  ],
  "novel_paths": [
    ["user:claude", "agent:chat-agent", "agent:read-agent", "resource:secret-db"]
  ],
  "capability_mismatches": [
    {
      "agent": "agent:read-agent",
      "status": "overreach",
      "declared_dependencies": ["resource:mock-database"],
      "observed_callees": ["resource:mock-database", "resource:secret-db"],
      "violating_edges": [{"source": "agent:read-agent", "target": "resource:secret-db"}]
    }
  ]
}
```

---

## Part 4: Decision Signal — No ML

### Philosophy

"What's normal" is defined by history, not a model. Compare each run against statistical baselines built from all previously ingested runs in SQLite.

### Baseline Types

**Set-based baselines** (has this ever happened before?):

Computed via simple `SELECT DISTINCT` queries against the `edges` and `paths` tables.

| Baseline | Query |
|----------|-------|
| `known_edges` | All distinct `(source, target, hop_kind)` across past runs |
| `known_paths` | All distinct `full_path` from `paths` table across past runs |
| `known_callees[agent]` | All targets this agent has ever called |
| `known_callers[agent]` | All sources that have ever called this agent |

**Percentile-based baselines** (is this within normal range?):

Computed via `GROUP BY run_id` aggregations, then p95 in Python.

| Baseline | How |
|----------|-----|
| `fanout_p95[agent]` | Per run: count distinct targets this agent called. Take p95. |
| `depth_p95` | Per run: max path length (principal to resource). Take p95. |
| `edge_count_p95[source,target]` | Per run: logical_count for this edge. Take p95. |
| `resource_access_p95` | Per run: count of agent_to_resource edges. Take p95. |

Baselines are computed on-the-fly from SQLite on each `/assess` call. No separate training step, no caching. This is fine at our scale (tens/hundreds of runs). If it gets slow, we can add a `baselines` table later.

### The 6 Scoring Rules

Each rule produces zero or more findings. Each finding has a fixed weight. The `risk_score` is the sum of all finding weights, capped at 100.

| # | Rule | Weight | Check |
|---|------|--------|-------|
| 1 | Novel edge | 15 per edge | Is `(source, target, hop_kind)` in `known_edges`? |
| 2 | Novel resource access | 20 per edge | Has this agent ever accessed this resource? Higher weight than #1 because resource access is more sensitive. |
| 3 | Depth exceeded | 10 | Max path length in this run > historical `depth_p95` |
| 4 | Fanout exceeded | 10 per agent | Agent's callee count this run > its `fanout_p95` |
| 5 | Retry storm / spike | 15 per edge | Edge `logical_count` > that edge's `edge_count_p95` |
| 6 | New delegation path | 10 per path | Is this `full_path` in `known_paths`? |

### Verdict Thresholds

| Verdict | Score Range |
|---------|-------------|
| `ok` | 0 – 25 |
| `warn` | 26 – 60 |
| `high` | 61 – 100 |

### Worked Example

Given 10 historical runs where read-agent always calls only mock-database, and chat-agent always fans out to 3 agents. A new run arrives:

- read-agent calls `resource:secret-db` (never seen)
  - **Novel edge**: +15
  - **Novel resource access**: +20
- chat-agent fans out to 5 agents (p95 was 3)
  - **Fanout exceeded**: +10
- Path `user:claude -> chat-agent -> read-agent -> secret-db` is new
  - **New delegation path**: +10

**Total: 55** -> verdict: **warn**

Every finding references exact edges and span_ids from the run's DAG.

### Cold Start

First run has no history. Everything is novel. The response will be:

```json
{
  "verdict": "high",
  "risk_score": 100,
  "baseline_runs": 0,
  "note": "No baseline data. This is the first ingested run. Subsequent runs will establish the baseline.",
  "reasons": [...]
}
```

Honest, not misleading. After a few normal runs, the baselines establish and novel findings drop to zero for expected behavior.

### Capability Alignment Check

For each agent node in the run's DAG:

1. Look up its agent card in the `agent_cards` table
2. Get observed callees from DAG edges (who it actually called this run)
3. Compare against declared `dependencies` in the card:
   - **aligned**: all observed callees are in declared dependencies
   - **overreach**: agent called something NOT in its declared dependencies
   - **unknown**: agent has no registered card

Each mismatch emits a `capability_mismatch` entry with the specific violating edges.

Capability mismatches do NOT contribute to the risk score directly — they are reported separately as a structural finding. This keeps the scoring rules purely behavioral (based on history) and the capability check purely declarative (based on cards).

---

## Implementation Order

1. **PVC + SQLite setup**: Add PersistentVolumeClaim, initialize database schema on startup
2. **Ingest logic**: Build the ingest function (Jaeger -> compute -> SQLite write)
3. **Migrate existing endpoints**: `/dag`, `/trust`, `/explain` read from SQLite first, fallback to Jaeger
4. **Agent card registration**: Mount card files, auto-load on startup, add API endpoints
5. **Assessment endpoint**: `/assess` with the 6 rules, baselines, capability alignment
6. **Testing**: Run multiple scenarios, verify baselines build, trigger findings

---

## Files Changed

| File | Change |
|------|--------|
| `k8s/workloads/lineage-service.yaml` | Major rewrite: SQLite init, ingest logic, migrated endpoints, assess endpoint, agent card API |
| `k8s/workloads/agent-cards/*.json` | Update `dependencies` to use full prefixed IDs |
| `k8s/workloads/lineage-pvc.yaml` | New: PersistentVolumeClaim for SQLite |
| `scripts/test-experiment4.sh` | New: Test script for decision surface |
