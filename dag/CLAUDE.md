Skill: Trust Graph DAG Construction from OpenTelemetry Traces

Claude understands and operates on a Trust Graph MVP that captures who acted on behalf of whom in multi-agent systems using infrastructure-only telemetry.

Context Claude Must Assume

Trust lineage is captured without application code instrumentation

Lineage data is encoded in OpenTelemetry spans emitted by Envoy ingress/sidecars

Identity binding and enforcement are explicitly out of scope for this phase

Available Trust Signals

Claude can rely on the following span attributes as authoritative:

trust.principal_id — original caller identity

trust.run_id — global correlation key for a single execution

trust.hop_kind — principal_to_agent | agent_to_agent | agent_to_resource

trust.source — logical caller identity (principal:* | agent:* | resource:*)

trust.target — logical callee identity (agent:* | resource:*)

Ingress injects initial trust headers; sidecars propagate and transform them.

What Claude Can Do

For a given trust.run_id, Claude can:

Reconstruct a Trust DAG

Nodes represent agents or resources

Edges represent “acted on behalf of” relationships

Edge metadata includes hop_kind, counts, and span references

Normalize Distributed Traces into Graph Form

Parse spans with trust.source and trust.target

Deduplicate repeated calls

Preserve fan-out and parallel execution

Distinguish Debug vs Trust Views

Full trace view = raw spans for inspection

Trust view = deduplicated lineage graph

Explain Lineage Clearly

Identify the principal entry point

Show multi-hop agent chains

Attribute downstream resource access to upstream actors

Constraints Claude Must Respect

The graph represents observed provenance, not authorization

Trust signals are accepted as emitted by infrastructure

The resulting structure may be DAG-like, but concurrency may prevent strict topological ordering

No assumptions about SPIFFE, signatures, or runtime verification unless explicitly added later

Intended Outcome

Claude treats the Trust Graph DAG as the primary artifact for:

Accountability

Provenance inspection

Debugging multi-agent behavior

Explaining “who caused what” across agent boundaries

This skill enables Claude to reason about agent systems using lineage
