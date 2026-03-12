# Trust DAG Construction Algorithm

This document explains how the Trust DAG is constructed from trust-tagged OpenTelemetry spans emitted by Envoy sidecars.

---

## Table of Contents

1. [Overview](#overview)
2. [Conceptual Model](#conceptual-model)
3. [Span Architecture](#span-architecture)
4. [DAG Construction Algorithm](#dag-construction-algorithm)
5. [Causal Chain Reconstruction](#causal-chain-reconstruction)
6. [Trust Lineage](#trust-lineage)
7. [Key Design Decisions](#key-design-decisions)
8. [Endpoints](#endpoints)
9. [Semantic Boundaries and Limitations](#semantic-boundaries-and-limitations)
10. [Correctness Guarantees](#correctness-guarantees)
11. [Performance Considerations](#performance-considerations)
12. [See Also](#see-also)

---

## Overview

The lineage service reconstructs delegation graphs from **independent sidecar traces** using **temporal backtracking**. Since Envoy sidecars create separate traces (no parent-child span references across services), we infer causality by matching timestamps and trust tags.

**Key insight**: Each hop in the delegation chain produces spans from multiple observation points (ingress, outbound sidecar, inbound sidecar). The DAG construction algorithm aggregates these observations while preserving provenance.

---

## Conceptual Model

### Root Node vs. Correlation ID

Understanding the distinction between `run_id` (correlation ID) and the root node (principal) is critical.

#### run_id (Correlation ID)

- **What**: UUID generated at ingress gateway
- **Propagated in**: `x-request-id` header
- **Tagged on spans**: `trust.run_id`
- **Purpose**: **Groups all spans belonging to one request**
- **Query**: `GET /api/traces?service=trust.run_id&tags={"trust.run_id":"550e8400-..."}`
- **Generated**: Once per request at ingress

#### Principal (Root Node)

- **What**: Original user identity extracted from OAuth token/auth header
- **Propagated in**: `x-principal-id` header (**immutable**)
- **Tagged on spans**: `trust.principal_id`
- **Purpose**: **Who authorized/initiated this request**
- **In DAG**: `dag["principal"] = "user:alice"`
- **Semantic meaning**: Root of the delegation chain

#### Why Both?

| Aspect | run_id | principal |
|--------|--------|-----------|
| **Purpose** | Technical correlation | Semantic identity |
| **Scope** | Single request | User across all requests |
| **Mutability** | Immutable per request | Immutable per request |
| **Uniqueness** | Unique per request | Shared across user's requests |
| **DAG role** | Correlation key to fetch spans | Root node in graph |

#### Complete Flow

```
1. Ingress Gateway:
   - Extracts principal: user:alice (from OAuth token)
   - Generates run_id: {550e8400-e29b-41d4-a716-446655440000}
   - Stamps headers:
     * x-principal-id: user:alice  (immutable)
     * x-request-id: {uuid}        (immutable)

2. Every network hop emits span with:
   - trust.run_id = {uuid}                  ← correlation
   - trust.principal_id = user:alice        ← root identity
   - trust.source = agent:chat              ← current caller
   - trust.target = agent:summary           ← current target

3. Lineage Service:
   - Queries Jaeger: "fetch all spans with trust.run_id={uuid}"
   - Reconstructs DAG:
     * dag["run_id"] = "{uuid}"             ← correlation
     * dag["principal"] = "user:alice"      ← root node
     * nodes: [user:alice, agent:chat, agent:summary, resource:db]
     * edges: [(user:alice → agent:chat), ...]
```

**Summary**: Principal (root node) extracted at ingress, run_id (correlation ID) injected at ingress. Network hops emit spans tagged with both. Runtime traces attach via run_id. DAG reconstructs delegation lineage from principal (root) through agents to resources.

### The First Edge: Ingress Span

The ingress gateway emits the **first span** when it forwards the user's request to the entry agent. This creates the **root edge** connecting the principal to the system.

#### Ingress Span Example

```json
{
  "spanID": "xyz789",
  "operationName": "outbound:agent:chat",
  "startTime": 1678901234567000,
  "tags": [
    {"key": "trust.source", "value": "user:alice"},
    {"key": "trust.target", "value": "agent:chat"},
    {"key": "trust.hop_kind", "value": "invoke"},
    {"key": "trust.principal_id", "value": "user:alice"},
    {"key": "trust.run_id", "value": "550e8400-e29b-41d4-a716-446655440000"}
  ]
}
```

This creates the **first edge** in the DAG:

```
user:alice → agent:chat
```

#### Full Chain Example

**Spans emitted** (in temporal order):

```
1. Ingress → chat-agent:
   trust.source: user:alice
   trust.target: agent:chat
   trust.hop_kind: invoke

2. chat-agent → summary-agent:
   trust.source: agent:chat
   trust.target: agent:summary
   trust.hop_kind: delegate

3. summary-agent → read-agent:
   trust.source: agent:summary
   trust.target: agent:read
   trust.hop_kind: delegate

4. read-agent → database:
   trust.source: agent:read
   trust.target: resource:mock-database
   trust.hop_kind: access
```

**DAG edges** (reconstructed):

```
1. user:alice → agent:chat                 ← from ingress span (root edge)
2. agent:chat → agent:summary              ← from chat sidecar
3. agent:summary → agent:read              ← from summary sidecar
4. agent:read → resource:mock-database     ← from read sidecar
```

**Key insight**: The ingress span is the **root edge** that connects the principal (user) to the system. Without it, the DAG would be disconnected — you'd have agent-to-agent and agent-to-resource edges, but no link back to who authorized the request.

The principal appears as a **node** in the DAG, but only as the `source` of the first edge. The principal never appears as a `target` — it is the ultimate authority that initiates the delegation chain.

---

## Span Architecture

### Trust-Tagged Span Format

Each Envoy sidecar emits OpenTelemetry spans with trust tags:

```json
{
  "spanID": "abc123",
  "operationName": "inbound:agent:summary",
  "startTime": 1678901234567000,
  "duration": 1234,
  "tags": [
    {"key": "trust.source", "value": "agent:chat"},
    {"key": "trust.target", "value": "agent:summary"},
    {"key": "trust.hop_kind", "value": "invoke"},
    {"key": "trust.run_id", "value": "550e8400-e29b-41d4-a716-446655440000"},
    {"key": "trust.principal_id", "value": "user:alice"}
  ]
}
```

These spans are collected from Jaeger via `/api/traces?service=trust.run_id&tags={"trust.run_id":"..."}`.

### Span Emission: Which Sidecars Emit?

**Answer: Both outbound and inbound sidecars emit spans for each hop.**

When `agent:chat` calls `agent:summary`:

```
Outbound sidecar (chat):
  operation: "outbound:agent:summary"
  trust.source: agent:chat      ← knows its own identity
  trust.target: agent:summary   ← from routing decision

Inbound sidecar (summary):
  operation: "inbound:agent:summary"
  trust.source: agent:chat      ← from request header x-caller-id
  trust.target: agent:summary   ← knows its own identity
```

**Both emit spans for the same hop: `agent:chat → agent:summary`**

#### Why Emit Both?

| Reason | Explanation |
|--------|-------------|
| **Defense in depth** | Cross-validate outbound claim against inbound observation |
| **Resilience** | If one sidecar fails to emit, the other provides coverage |
| **Richer context** | Outbound has client-side timing, inbound has server-side timing |
| **Discrepancy detection** | If outbound says "I called X" but inbound at Y says "I received from Z", anomaly detected |

#### DAG Aggregation

The DAG construction algorithm **deduplicates** these observations:

```json
{
  "source": "agent:chat",
  "target": "agent:summary",
  "count": 2,           // Both outbound and inbound spans observed
  "logical_count": 2,   // 2 unique span IDs
  "span_ids": ["abc123", "def456"]
}
```

### Security: Is trust.source Authoritative?

**Current Implementation: NOT Authoritative** ⚠️

`trust.source` is currently set from **request headers**:

```yaml
# Sidecar reads x-caller-id from incoming request
trust.source = request_headers["x-caller-id"]
```

**Security implication**: A compromised agent can **lie** about its identity by manipulating headers.

#### Attack Scenario

```
Malicious agent:read sends request with forged headers:
  x-caller-id: "agent:admin"  ← LIE
  x-trust-target: "resource:mock-database"

Sidecar blindly trusts the header:
  trust.source = "agent:admin"  ← stamped on span

DAG shows:
  agent:admin → resource:mock-database  ← FALSE ATTRIBUTION
```

The lineage shows "admin accessed the database" when it was actually "read" — the audit trail is corrupted.

#### Authoritative Alternative: Workload Identity

**Secure approach**: Sidecar extracts identity from **cryptographically verifiable sources**:

| Source | Mechanism | Trust Level |
|--------|-----------|-------------|
| **Kubernetes Service Account Token** | JWT with pod identity, signed by K8s API server | High (cluster trust boundary) |
| **mTLS Certificate** | X.509 cert in SPIFFE format, validated via TLS handshake | Very High (cryptographic) |
| **Envoy's `x-forwarded-client-cert`** | Extracted from mTLS connection metadata | High (requires mutual TLS) |

**Production recommendation**: Sidecar MUST extract `trust.source` from workload identity (service account, mTLS cert, SPIFFE ID), not from request headers.

#### The Trust Model

```
Outbound span: Caller's perspective ("I called agent:summary")
Inbound span: Callee's perspective ("I was called by agent:chat")

If trust.source comes from headers → both can be forged
If trust.source comes from mTLS → inbound span is authoritative
```

**Most secure**: Inbound sidecar with mTLS peer certificate extraction — it knows:
- `trust.target`: Its own workload identity (authoritative)
- `trust.source`: Peer's certificate SPIFFE ID (cryptographic proof)

**Security Note**: The demo implementation sets `trust.source` from request headers for simplicity. In production, sidecars MUST extract identity from cryptographically verifiable sources (service account tokens, mTLS certificates, SPIFFE IDs) to prevent compromised agents from forging their identity in the lineage.

---

## DAG Construction Algorithm

**Location**: `lineage-service.yaml`, lines 1025-1129

### Step 1: Collect All Spans

Flatten all traces into a single list of spans. Filter for spans containing `trust.*` tags.

### Step 2: Build Nodes

For each span with trust tags:

```python
source = trust_tags.get("trust.source")
target = trust_tags.get("trust.target")

# Create node for source (if not exists)
if source not in nodes:
    nodes[source] = {
        "id": source,
        "type": get_node_type(source),  # principal | agent | resource
        "label": source.split(":")[-1]   # e.g., "chat" from "agent:chat"
    }

# Create node for target (if not exists)
if target not in nodes:
    nodes[target] = {...}
```

**Node type determination** (from ID prefix):
- `user:*` or `principal:*` → `principal`
- `agent:*` → `agent`
- `resource:*` → `resource`

### Step 3: Build Edges

For each span, create or update the edge `(source → target)`:

```python
edge_key = (source, target)

if edge_key not in edges:
    edges[edge_key] = {
        "source": source,
        "target": target,
        "hop_kind": hop_kind,
        "count": 0,              # Raw span count (includes duplicates)
        "span_ids": [],          # Unique span IDs
        "first_ts": start_time,  # Earliest observation
        "last_ts": start_time,   # Latest observation
        "total_duration_us": 0   # Sum of span durations
    }

edges[edge_key]["count"] += 1
edges[edge_key]["span_ids"].append(span_id)
edges[edge_key]["total_duration_us"] += duration
edges[edge_key]["first_ts"] = min(edges[edge_key]["first_ts"], start_time)
edges[edge_key]["last_ts"] = max(edges[edge_key]["last_ts"], start_time)
```

**Key insight**: The same edge (A → B) may be observed multiple times:
- From ingress gateway span
- From caller's outbound sidecar span
- From target's inbound sidecar span

We aggregate these observations while tracking:
- `count`: Total raw observations
- `logical_count`: Number of unique span IDs (deduplicated)

### Step 4: Output DAG

```json
{
  "run_id": "550e8400-e29b-41d4-a716-446655440000",
  "principal": "user:alice",
  "nodes": [
    {"id": "user:alice", "type": "principal", "label": "alice"},
    {"id": "agent:chat", "type": "agent", "label": "chat"},
    {"id": "agent:summary", "type": "agent", "label": "summary"},
    {"id": "resource:mock-database", "type": "resource", "label": "mock-database"}
  ],
  "edges": [
    {
      "source": "user:alice",
      "target": "agent:chat",
      "hop_kind": "invoke",
      "count": 2,
      "logical_count": 1,
      "span_ids": ["abc123"],
      "first_ts": 1678901234567000,
      "last_ts": 1678901234568000,
      "total_duration_us": 2468
    },
    {
      "source": "agent:chat",
      "target": "agent:summary",
      "hop_kind": "delegate",
      "count": 3,
      "logical_count": 2,
      "span_ids": ["def456", "ghi789"],
      ...
    }
  ],
  "summary": {
    "total_nodes": 4,
    "total_edges": 3,
    "principals": 1,
    "agents": 2,
    "resources": 1
  }
}
```

### Retry Semantics

If the same hop happens multiple times (e.g., retries):

```
agent:summary → resource:db
agent:summary → resource:db
agent:summary → resource:db
```

**Current implementation**: One edge, count = 6 (3 retries × 2 sidecars)

```json
{
  "source": "agent:summary",
  "target": "resource:db",
  "count": 6,           // 3 retries × 2 sidecars (outbound + inbound)
  "logical_count": 6,   // 6 unique span IDs
  "span_ids": ["span1", "span2", "span3", "span4", "span5", "span6"],
  "first_ts": 1678901234567000,  // First retry timestamp
  "last_ts": 1678901234789000    // Last retry timestamp
}
```

**Semantic**: The DAG represents **logical delegation structure**, not temporal execution. Retries are aggregated into edge counts.

**Use `logical_count`** to see unique span observations (deduplicated across instrumentation points).

**Use `first_ts` / `last_ts`** to see the retry time window.

**For per-retry visibility**: Use `/lineage/{run_id}` (full debug view) which shows all spans individually, or implement a future `/lineage/{run_id}/timeline` endpoint.

**Retry Storm Detection**: In the assess/anomaly detection framework:

```python
if edge["logical_count"] > 10:
    flag_anomaly("retry_storm", edge)
```

---

## Causal Chain Reconstruction

**Location**: `lineage-service.yaml`, lines 1236-1290

**Problem**: Envoy sidecars create **independent traces** with no parent-child span references across services. How do we reconstruct the causal chain `user → agent-A → agent-B → resource`?

**Solution**: Walk backwards in time, matching `trust.target` to find the "calling" span.

### Algorithm: `reconstruct_causal_chain()`

Given a target span (e.g., `agent:summary → resource:db` at timestamp 300):

1. **Initialize chain** with the target span
2. **Set current_actor** = `trust.source` of target span (e.g., `agent:summary`)
3. **While** current_actor is not a principal:
   - Find the most recent **inbound span** where:
     - `trust.target == current_actor`
     - `start_time < current_timestamp`
   - Add this span to the chain
   - Update `current_actor` to the `trust.source` of this span
   - Update `current_timestamp` to the `start_time` of this span
4. **Reverse** the chain to get root → leaf order

### Example

**Spans** (sorted by timestamp):

```
t=100: user:alice → agent:chat     [operation: inbound:agent:chat]
t=200: agent:chat → agent:summary  [operation: inbound:agent:summary]
t=300: agent:summary → resource:db [operation: inbound:resource:db]
```

**Reconstruct causal chain** for span at t=300:

```
Step 1: target_span = (agent:summary → resource:db, t=300)
        chain = [(agent:summary → resource:db, t=300)]
        current_actor = "agent:summary"
        current_ts = 300

Step 2: Find most recent span with target="agent:summary" before t=300
        → Found: (agent:chat → agent:summary, t=200)
        chain = [(agent:summary → resource:db, t=300),
                 (agent:chat → agent:summary, t=200)]
        current_actor = "agent:chat"
        current_ts = 200

Step 3: Find most recent span with target="agent:chat" before t=200
        → Found: (user:alice → agent:chat, t=100)
        chain = [(agent:summary → resource:db, t=300),
                 (agent:chat → agent:summary, t=200),
                 (user:alice → agent:chat, t=100)]
        current_actor = "user:alice"

Step 4: user:alice is type=principal → STOP

Step 5: Reverse chain
        → [(user:alice → agent:chat, t=100),
           (agent:chat → agent:summary, t=200),
           (agent:summary → resource:db, t=300)]
```

**Result**: Full causal chain from principal to resource.

### Preference for Inbound Spans

When searching for parent spans, the algorithm **prefers** spans with operation names starting with `inbound:*`:

```python
if s["operation"].startswith("inbound:"):
    parent_span = s
    break
elif parent_span is None:
    parent_span = s  # Fallback to outbound or other spans
```

**Reason**: Inbound listener spans are more reliable markers of when a service was invoked. Outbound spans are emitted by the caller and may have slight timestamp variations.

---

## Trust Lineage

**Location**: `lineage-service.yaml`, lines 1527-1622

This builds a **topologically ordered event list** — all causal hops in temporal order, including duplicated edges from different delegation paths.

### Differences from DAG

| DAG (`/dag`) | Trust Lineage (`/trust`) |
|--------------|--------------------------|
| Deduplicated edges | All hops (duplicates included) |
| `(source, target)` aggregated | Each hop with full `causal_path` |
| Graph structure (nodes + edges) | Sequential event list |

### Algorithm: `build_trust_lineage()`

1. **Find leaf spans** (endpoints of delegation chains):
   - Resource access spans: `target` is a resource
   - Terminal agent spans: `target` is an agent that never appears as a `source`

2. **Reconstruct causal chain** for each leaf span (using temporal backtracking)

3. **Deduplicate events by causal context**:
   - Key: `(source, target, causal_path)`
   - The same edge `(agent:chat → agent:read)` may appear twice with different paths:
     - Path 1: `[user:alice, agent:chat, agent:read]`
     - Path 2: `[user:alice, agent:chat, agent:summary, agent:read]`
   - Both are **kept as separate events** because they have different causal contexts

4. **Sort by timestamp** (topological approximation)

### Output Example

```json
{
  "run_id": "550e8400-...",
  "type": "topologically_ordered_event_list",
  "principal": "user:alice",
  "total_events": 5,
  "trust_chain": [
    {
      "step": 1,
      "hop_kind": "invoke",
      "source": "user:alice",
      "target": "agent:chat",
      "span_duration_us": 1234,
      "causal_path": ["user:alice", "agent:chat"]
    },
    {
      "step": 2,
      "hop_kind": "delegate",
      "source": "agent:chat",
      "target": "agent:summary",
      "span_duration_us": 2345,
      "causal_path": ["user:alice", "agent:chat", "agent:summary"]
    },
    {
      "step": 3,
      "hop_kind": "delegate",
      "source": "agent:chat",
      "target": "agent:read",
      "span_duration_us": 3456,
      "causal_path": ["user:alice", "agent:chat", "agent:read"]
    },
    ...
  ]
}
```

**Note**: Steps 2 and 3 both originate from `agent:chat` but have different targets and causal paths. This represents parallel delegation.

---

## Key Design Decisions

### 1. No Parent-Child Span References

**Why**: Envoy sidecars create independent traces. Each sidecar emits spans with `parent_span_id=0` (root spans).

**Solution**: Use temporal backtracking with trust tags instead of OpenTelemetry span parent references.

### 2. Causal Path Deduplication

**Why**: The same edge may be traversed multiple times via different delegation paths.

**Example**:
```
user → agent:chat
  ├─> agent:read → db
  └─> agent:summary → agent:read → db
```

The edge `agent:read → db` appears twice with different causal paths:
- `[user, chat, read, db]`
- `[user, chat, summary, read, db]`

**Decision**: Keep both in `/trust` endpoint (for provenance), deduplicate in `/dag` endpoint (for graph structure).

### 3. Edge Aggregation

**Why**: The same edge may be observed from multiple spans (ingress, caller sidecar, target sidecar).

**Decision**: Track both:
- `count`: Raw observations (includes duplicates from different instrumentation points)
- `logical_count`: Unique span IDs (deduplicated)

### 4. Inbound Span Preference

**Why**: Outbound spans are emitted by the caller before the request completes. Inbound spans are emitted by the target when it receives the request — more reliable for timestamp ordering.

**Decision**: Prefer `operation.startsWith("inbound:")` when backtracking.

### 5. Both Sidecars Emit Spans

**Why**: Defense in depth, resilience, discrepancy detection.

**Decision**: Both outbound (caller) and inbound (callee) sidecars emit spans for each hop. DAG construction deduplicates them.

---

## Endpoints

| Endpoint | Output | Use Case |
|----------|--------|----------|
| `/lineage/{run_id}` | Full debug view (all spans) | Debugging, raw trace inspection |
| `/lineage/{run_id}/trust` | Topologically ordered event list | Provenance, audit trail |
| `/lineage/{run_id}/dag` | DAG (nodes + edges) | Visualization, graph analysis |
| `/lineage/{run_id}/dag?format=dot` | Graphviz DOT format | Graph rendering |
| `/lineage/{run_id}/explain?node=...` | Provenance explanation | "Why did this node get accessed?" |

---

## Semantic Boundaries and Limitations

This section documents **semantic gaps** and design decisions around asynchronous work, tool modeling, and run boundaries.

### 1. Async/Queued Work — How DAG Represents Delayed Execution

#### The Problem

When work is queued for delayed execution, temporal backtracking breaks:

```
t=0:     user → agent:orchestrator → queue:tasks (enqueue)
t=600s:  queue:tasks → agent:worker → resource:db (execution)
```

**Issue**: The algorithm looks for "most recent inbound span before current timestamp" — with a 10-minute gap, it won't find the orchestrator span. The causal chain is broken.

#### Current Implementation

**The demo does NOT support async/queued work.** All work must be **request-scoped** (synchronous).

When the ingress gateway generates a `run_id`, it assumes:
- Work begins when request arrives
- Work ends when response returns
- All spans arrive within the request duration

Async work that executes after the response returns **cannot use the same run_id** because the temporal backtracking window is too narrow.

#### Options for Future Support

| Approach | Description | Pro | Con |
|----------|-------------|-----|-----|
| **Same run_id + Queue Node** | Queue middleware propagates trust headers in message metadata. Worker reads `run_id` when dequeuing. Both enqueue and dequeue emit spans. | Full provenance chain visible: `user → orchestrator → queue → worker → db` | Requires instrumenting queue infrastructure |
| **New run_id + Parent Linkage** | Orchestrator creates child `run_id` and stores `parent_run_id` in message. Worker uses child `run_id` for its work. | Each synchronous phase is a separate bounded DAG | Lose single-graph view, need "trace tree" UI |
| **Edge Metadata (Async Marker)** | Single edge `orchestrator → worker` with metadata: `{via_queue: "tasks", async: true, delay_seconds: 600}` | Preserves DAG structure | Hides queue as intermediary node, harder to model queue failures |

#### Recommendation

**Demo**: Document as **not supported**. Add to limitations section:

> **Async Work**: The current implementation assumes synchronous request-scoped execution. Asynchronous work (queues, webhooks, scheduled tasks) that executes after the response returns is not supported. Future work: add `parent_run_id` field for hierarchical run correlation.

**Production**: Implement **hierarchical run_ids** (Option 2):
- Parent run represents the user request
- Child runs represent async tasks spawned by the parent
- Lineage service supports parent-child queries: `GET /lineage/{run_id}/children`

---

### 2. Tool Modeling — Tool as Agent or Resource Node Type

#### The Problem

How should "tools" be modeled in the DAG? Examples:
- `search_tool` (calls external API)
- `calculator_tool` (local computation)
- `web_scraper_tool` (fetches + parses HTML)
- `llm_tool` (calls another LLM, which itself may call tools)

Is a tool an **agent** (makes decisions, delegates) or a **resource** (passive, responds to requests)?

#### Current Implementation

Node type is determined by **ID prefix**, not semantic behavior:

```python
def get_node_type(self, node_id):
    if node_id.startswith("user:") or node_id.startswith("principal:"):
        return "principal"
    elif node_id.startswith("agent:"):
        return "agent"
    elif node_id.startswith("resource:"):
        return "resource"
    return "unknown"
```

**The demo has no tools** — only agents (chat, summary, read, sales) and resources (mock-database). The distinction is **prefix-based**, not behavior-based.

#### Semantic Distinction

| Node Type | Behavior | Can Delegate? | Examples |
|-----------|----------|---------------|----------|
| **Agent** | Makes autonomous decisions | ✅ Yes | chat-agent, summary-agent, orchestrator |
| **Resource** | Passive data/compute | ❌ No | database, file storage, cache |
| **Tool** | ??? | ??? | search API, calculator, web scraper |

#### The Agentic Tool Problem

Consider a search tool that aggregates results from multiple sources:

```
agent:orchestrator → tool:search → api:google
                                 → api:bing
                                 → api:wikipedia
```

**Question**: If `tool:search` delegates to multiple APIs, is it an agent?

#### Options

| Approach | Rationale | Example | Pro | Con |
|----------|-----------|---------|-----|-----|
| **Tools Are Resources** | Tools are capabilities invoked by agents, even if they call external services | `agent:orchestrator → resource:search_tool → resource:google_api` | Simple, uses existing types | Loses the semantic that search_tool is "active" |
| **Tools Are Agents (If They Delegate)** | If a tool can delegate, it's an agent | `agent:orchestrator → agent:search_tool → resource:google_api` | Preserves delegation semantics | Blurs line between "agent" (reasoning) and "tool" (specialized function) |
| **Add "Tool" Node Type** | Explicit category for tools | `agent:orchestrator → tool:search → resource:google_api` | Clear semantic distinction | Adds complexity, need tool-specific policies |
| **Context-Dependent** | Simple tools (local) = not nodes. Service tools (API) = resources. Agentic tools (delegate) = agents. | Varies by tool | Matches behavior | Ambiguous categorization |

#### Recommendation

**Demo**: Use existing types based on delegation behavior:
- **Simple tools** (local computation): Not represented as nodes — internal agent execution
- **Service tools** (single API call, no delegation): Use `resource:` prefix
  - Example: `agent:chat → resource:calculator_api`
- **Agentic tools** (can delegate to multiple services): Use `agent:` prefix
  - Example: `agent:chat → agent:search_tool → resource:google_api`

Document the distinction:

> **Tool Modeling**: Tools are modeled based on delegation behavior. Tools that make a single API call without further delegation use the `resource:` prefix. Tools that delegate to multiple services use the `agent:` prefix. Simple computational tools (e.g., local math operations) are not represented as nodes — they're internal agent execution.

**Production**: Add **explicit "tool" node type** (Option 3):
- Tools can delegate (unlike resources)
- Tools don't make autonomous decisions (unlike agents)
- Tools have **declared capabilities** (agent cards for tools)
- Policy engine can enforce tool-specific restrictions (e.g., "agent:chat can only invoke tools declared in its capability card")

---

### 3. Run Boundary — What Defines Start/End of a run_id

#### The Problem

When does a `run_id` start and end?

**Start** is clear: Ingress gateway generates `{uuid.uuid4()}` when request arrives.

**End** is ambiguous.

#### Scenarios That Break the Model

| Scenario | Description | Question |
|----------|-------------|----------|
| **Synchronous Request** | User request completes in 500ms, all work finishes before response | ✅ Works: `run_id` lifecycle = request duration |
| **Fire-and-Forget** | User request returns 202 Accepted immediately, work executes 10s later | ❓ Should worker use same `run_id`? If yes, run never "ends" from ingress perspective. If no, who generates new `run_id`? |
| **Streaming** | Agent opens stream, emits 100 chunks over 10 minutes | ❓ All chunks same `run_id` (graph shows `agent → llm` with `count=100`) or separate `run_id`s (lose correlation)? |
| **Batch** | User submits batch with 100 items, orchestrator fans out to 100 workers | ❓ One `run_id` (aggregate view) or 100 `run_id`s (per-item tracing)? |

#### Current Implementation

**Request-scoped** runs (synchronous only):

- `run_id` starts when ingress receives request
- `run_id` ends when response returns to user (implicit)
- All spans must arrive within request duration
- No explicit "seal" or "end" signal

**This works for synchronous request/response but breaks for async, streaming, and batch patterns.**

#### Options for Run Boundaries

| Approach | Definition | Pro | Con |
|----------|-----------|-----|-----|
| **Request-Scoped (Current)** | `run_id` ends when HTTP response returns | Simple, maps to request/response model | Doesn't handle async, streaming, or batch |
| **Correlation-Scoped** | `run_id` propagates through **all causally related work**, including async delayed by hours | Complete provenance across async boundaries | Runs never "end" until all async work completes (hard to determine), unbounded trace collection |
| **Hierarchical run_ids** | Parent run for request (`{uuid1}`), child runs for async work (`{uuid2}` with `parent_run_id={uuid1}`) | Bounded runs, trace tree structure, clear parent-child semantics | More complex, need parent-child correlation in UI |
| **Explicit Boundaries** | Application calls `POST /lineage/{run_id}/seal` to signal completion | Application controls semantic boundary | Requires instrumentation, easy to forget |

#### Examples: Hierarchical run_ids

**Fire-and-Forget**:
```
Parent run: {uuid1}
  DAG: user → orchestrator → queue
  Status: sealed at t=100ms (response returned)

Child run: {uuid2} (parent_run_id={uuid1})
  DAG: queue → worker → db
  Status: sealed at t=600s (worker finished)
```

**Batch**:
```
Parent run: {uuid1}
  DAG: user → orchestrator → (fan-out to 100 workers)

Child runs: {uuid2..uuid101} (each with parent_run_id={uuid1})
  DAG: worker[N] → db
```

**Streaming**:
```
Parent run: {uuid1}
  DAG: user → agent (stream opened)

Child runs: {uuid2..uuid101} (one per chunk)
  DAG: agent → llm (chunk N)
```

#### Recommendation

**Demo**: Define as **request-scoped** and document the limitation:

> **Run Boundary**: A `run_id` represents a single synchronous request. The run starts when the ingress gateway receives the request and implicitly ends when the response returns to the user. All spans must be emitted within the request duration (typically <10s). Asynchronous work, streaming, and batch processing are **not supported** in the current implementation. Future work: implement hierarchical `run_id`s with `parent_run_id` field for async correlation.

**Production**: Implement **hierarchical run_ids** (Option 3):
- Add `parent_run_id` field to trust tags
- Ingress generates parent `run_id` for user request
- When spawning async work, agent generates child `run_id` and sets `parent_run_id`
- Queue middleware propagates both in message headers
- Lineage service supports queries:
  - `GET /lineage/{run_id}` — single run DAG
  - `GET /lineage/{run_id}/children` — all child runs
  - `GET /lineage/{run_id}/tree` — parent + all descendants
- UI displays trace tree with collapsible parent/child relationships

Add explicit sealing (Option 4) for long-running work:
- `POST /lineage/{run_id}/seal` called when work completes
- Prevents further span ingestion for sealed runs
- Enables "complete" vs "in-progress" status in UI

---

## Correctness Guarantees

### What the Algorithm Guarantees

1. **All causal hops are captured**: Every delegation in the trust chain appears in `/trust` endpoint
2. **Temporal ordering**: Events are sorted by timestamp (approximates topological order)
3. **Provenance tracking**: Each event includes full `causal_path` from principal to target
4. **No false edges**: Only edges with explicit trust tags are included (no inference)

### What the Algorithm Does NOT Guarantee

1. **Perfect topological order**: Timestamps may have clock skew across nodes (but sorted within single node's spans)
2. **Cycle detection**: If agents call each other recursively, backtracking stops at max depth (10 hops)
3. **Concurrent execution ordering**: Spans emitted in parallel may have arbitrary ordering in the event list
4. **Identity authenticity**: If `trust.source` comes from request headers (current demo), a compromised agent can forge its identity. Production must use workload identity extraction.

---

## Performance Considerations

- **Lazy ingestion**: First request to `/lineage/{run_id}/*` triggers span fetch from Jaeger and stores result in SQLite
- **SQLite caching**: Subsequent requests read from SQLite (no Jaeger query)
- **Time complexity**: O(N²) in worst case for backtracking (N = number of spans), but typically O(N·D) where D = delegation depth (~3-5 hops)

---

## See Also

- **Architecture**: `/home/claude/trust-aware-dataplane/architecture.md`
- **Blog Post**: `/home/claude/trust-aware-dataplane/blog-post.md`
- **Lineage Service Implementation**: `/home/claude/trust-graph-otel/k8s/workloads/lineage-service.yaml`
- **RFC (AuthBroker)**: `/home/claude/trust-graph-otel/CLAUDE.md`
