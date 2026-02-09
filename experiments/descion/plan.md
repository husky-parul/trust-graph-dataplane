# Skill: Trust Graph Decision Surface (Path 1)

Claude can treat the Trust Graph DAG + explain outputs as a decision surface: not enforcement, but signal about whether an agent run looks expected vs suspicious.

## Inputs Claude Can Assume Exist

1. Trust DAG endpoint: nodes + edges per run_id, with deduped edge span IDs, counts, and timing. 

2. Explain endpoint: per-target “why” view with per-path attribution (cause_groups, full_path, span_ids) and a stable delegation_order. 

3. Event list endpoint: topologically/temporally ordered hops with a causal_path per hop. 


## What Claude Should Produce

Add a new endpoint and semantics:

- GET /lineage/{run_id}/assess

    - returns verdict: ok | warn | high

    - risk_score: 0-100 (simple weighted sum)

    - reasons[] (each reason references edges/paths/span_ids)

    - novel_edges[] and novel_paths[]

    - capability_mismatches[] (if agent cards are available)

## Minimal Baseline Model (No ML)

Maintain lightweight baselines over recent runs:

- Per-agent:

    - typical callees (agents/resources)

    - typical callers

    - typical hop kinds

    - typical fanout / depth (p95)

    - typical edge call counts (p95)

- Per-run:

    - number of nodes/edges

    - number of resource accesses

## Judgement Rules (First Version)

Flag and score:

- Novel edge: unseen (source,target,hop_kind) compared to baseline

- Novel resource access: agent touches a resource it hasn’t before

- Depth exceeded: max principal→…→resource path length > baseline p95

- Fanout exceeded: agent fans out to too many agents/resources > baseline p95

- Retry storm / spike: edge count or logical_count spikes vs baseline p95 

- New delegation path: unseen full_path appears 

## Capability Alignment Check (If Agent Cards Exist)

- Compare

    - observed_calls(agent) derived from DAG edges vs declared_capabilities(agent_card)

- Emit:

    - aligned | overreach | unknown, and list violating edges/paths.

## Constraints

This layer provides observed provenance judgement, not authorization.

No SPIFFE / registry binding / enforcement assumptions are made.

All reasons must point back to concrete DAG edges, explain paths, or span IDs.

## Feature Enhancements

Right now you’re deriving three “products” from Jaeger:

1. the deduped DAG (/trust) with count vs logical_count, span IDs, and edge timings 

2. the explain output with per-path attribution (cause_groups, full_path, per-span tracking) 

3. the event list (topological/temporal chain) 


Those are already stable artifacts worth materializing.

### What I’d do next (minimal, clean)

Keep Jaeger as the raw source-of-truth, but add a small store for derived lineage artifacts.

Store keyed by:

- run_id

- artifact_type: dag | explain | trust_chain | assess

- version (so you can change schema safely)

- computed_at

- inputs: trace_id(s), span_id set, and maybe “jaeger query params” so you can reproduce

### Why storage matters now?

- Retention: Jaeger is usually short-lived; your decision surface needs weeks/months.

- Performance: rebuilding graphs for every query is fine now, but will suck once you start doing baselines/anomaly checks.

- Baselines: needs historical distributions (fanout, depth, novel edges, etc.). You can’t do that reliably by re-querying Jaeger every time.


## What to do next (SQLite canonical lineage store)
1) Create 4 tables (minimum viable + defensible)

    - runs (one row per run_id)

    - nodes (typed node registry per run)

    - edges (deduped edges per run)

    - edge_spans (optional but recommended for clean queries; avoids JSON arrays)

    Key design choice: make runs append-only / sealed.

2) Change your flow to “ingest then serve”

    Instead of “serve by re-reading Jaeger”:

    Ingest:

    - fetch spans from Jaeger for run_id

    - compute DAG + explain + trust_chain

    - write to SQLite in one transaction

    - mark run sealed=1 with content_hash

    Serve:

    - /trust, /explain, /chain read from SQLite

    - Jaeger is only used if run not ingested yet (optional fallback)

3) Decide what’s canonical (be strict)

    - Canonical = nodes + edges + span_ids references + principal + timestamps + hash
    - Not canonical = raw Jaeger spans.

    - Minimal schema

        - runs(run_id PK, principal_id, started_at, ended_at, ingested_at, sealed, schema_version, content_hash)

        - nodes(run_id, node_id, type, label, PRIMARY KEY(run_id,node_id))

        - edges(run_id, source, target, hop_kind, logical_count, raw_count, first_ts, last_ts, total_duration_us, PRIMARY KEY(run_id,source,target,hop_kind))

        - edge_spans(run_id, source, target, hop_kind, span_id, PRIMARY KEY(run_id,source,target,hop_kind,span_id))

That’s enough to reconstruct your DAG endpoint exactly.