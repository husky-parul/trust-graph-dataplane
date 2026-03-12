# RFC: AuthBroker – Trust-Aware Authorization for Agent → Tool → Resource Flows

**Status**: Draft
**Author**: [Author Name]
**Created**: 2026-03-11
**Last Updated**: 2026-03-11

## Abstract

This RFC proposes **AuthBroker**, a trust-aware authorization framework for AI agent systems where requests flow across multiple trust boundaries: `user → agent → tool → resource`. The proposal integrates existing identity infrastructure (Keycloak, AuthBridge) with AuthBroker, a dataplane that acts as a Policy Enforcement Point (PEP) at each service boundary. The goal is to enable dynamic, request-level authorization decisions while preserving the existing credential acquisition and verification layers.

## 1. Problem Statement

### 1.1 Interaction Model

AI agent systems execute requests across multiple services and tools:

```
user → agent → tool → resource
```

Each hop introduces a trust boundary where:
- Identity must be verified
- Authorization decisions may be required
- Delegation context must be preserved

### 1.2 Current Limitations

Today, authorization logic is implemented through static configuration:
- Role mappings
- Scope → audience mappings
- Token-based access control with fixed audiences

These mechanisms **do not support**:
- Restricting which agents can invoke specific tools
- Restricting which resources a tool may access based on request context
- Evaluating policy based on runtime attributes (delegation chain, request content, historical behavior)
- Dynamic descoping of privileges at runtime

### 1.3 Missing Capabilities

Examples of **runtime policy questions** that cannot be answered by credentials alone:
- Has the delegation chain `user-Y → agent-A → tool-X` been observed before in production?
- Should this request be denied because the delegation depth exceeds policy limits (e.g., user → agent → agent → agent → tool)?
- Does this request represent a capability overreach (agent normally reads data, now attempting write)?
- Should access be blocked because the delegation graph shows anomalous fanout (one agent invoking 20 different tools)?
- Can `tool-X` access `resource-Z` given that the principal's data classification is "sensitive" and the tool's capability card declares "read-only"?

**Note**: OBO token exchange answers "Can agent-A obtain credentials to act on behalf of user-Y?" AuthBroker answers "Should this specific request proceed given runtime context and policy?"

## 2. Existing Components

### 2.1 Identity / Credential Layer

**Keycloak** provides:
- OAuth token issuance
- Token exchange (OBO / delegation) for downstream service credentials

### 2.2 AuthBridge

Acts as a Policy Enforcement Point (PEP):
- Validates incoming tokens
- Verifies audience claims
- Performs token exchange via Keycloak
- Forwards requests to downstream services

**Current limitation**: Policy enforcement is limited to accepting valid tokens with the correct audience. No request-level authorization logic.

## 3. Proposal

### 3.1 Authorization Layers (Separation of Concerns)

The system involves **three distinct layers** that should not be conflated:

| Layer | Mechanism | Component | Purpose |
|-------|-----------|-----------|---------|
| **Credential Acquisition** | OBO token exchange | Keycloak | Determines whether a service *can obtain credentials* to act on behalf of another identity |
| **Credential Verification** | Token validation, audience verification | AuthBridge | Ensures the presented credential *is valid* and has the correct audience |
| **Authorization** | Runtime policy evaluation (allow / deny) | **AuthBroker** | Determines whether a specific request *should proceed* given context, delegation chain, and policy |

**Key insight**: A service may have valid credentials (layers 1 & 2 pass) but still be denied by policy (layer 3). Example: agent-A has a valid OBO token for tool-X, but AuthBroker denies because the delegation pattern `user-Y → agent-A → tool-X` has never been observed before and violates anomaly detection policy.

### 3.2 Role of AuthBroker

AuthBroker focuses on **runtime request enforcement at service boundaries**.

In this model:
- AuthBroker acts as a **PEP at hop boundaries**
- Verified identity and request context are evaluated **before forwarding requests**
- Policy decisions are made by querying pluggable Policy Decision Points (PDPs)

Example checks:
- `agent → tool` allowed?
- `tool → resource` allowed?
- Does the delegation chain match expected patterns?
- Are there anomaly signals (novel edge, depth exceeded, capability overreach)?

**Key principle**: AuthBroker does not replace token exchange. Instead, it **consumes** the credentials issued by the identity layer and uses them as **inputs for policy evaluation**.

### 3.3 Architecture

```
┌─────────────┐
│   User      │
└──────┬──────┘
       │ [1] Request + credentials
       ▼
┌─────────────────────────────────────────┐
│  Ingress Gateway (PEP)                  │
│  - Extract principal identity           │
│  - Stamp trust headers (x-principal-id) │
│  - Query PDP: allow ingress?            │
└──────┬──────────────────────────────────┘
       │ [2] Forwarded with trust headers
       ▼
┌─────────────────────────────────────────┐
│  Agent Service + Sidecar (PEP)          │
│  - Validate token (AuthBridge)          │
│  - Query PDP: agent → tool allowed?     │
│  - Emit trust-tagged span               │
└──────┬──────────────────────────────────┘
       │ [3] Delegated request
       ▼
┌─────────────────────────────────────────┐
│  Tool Service + Sidecar (PEP)           │
│  - Validate token (AuthBridge)          │
│  - Query PDP: tool → resource allowed?  │
│  - Emit trust-tagged span               │
└──────┬──────────────────────────────────┘
       │ [4] Resource access
       ▼
┌─────────────────────────────────────────┐
│  Resource (database, API, etc.)         │
└─────────────────────────────────────────┘

Telemetry Path:
All sidecars → OTel Collector → Trace Backend → Lineage Service
```

### 3.4 Trust Headers

Headers propagated through the delegation chain:

| Header | Mutability | Purpose |
|--------|-----------|---------|
| `x-principal-id` | **Immutable** | Original user identity (set once at ingress) |
| `x-request-id` | **Immutable** | Request correlation ID |
| `x-caller-id` | Mutable | Current caller identity (updated at each hop) |
| `x-caller-type` | Mutable | Type of caller (user, agent, tool) |
| `x-trust-hop-kind` | Mutable | Type of delegation (invoke, delegate, access) |
| `x-trust-target` | Mutable | Target service for current hop |

### 3.5 Policy Decision Points (PDPs)

AuthBroker integrates with **pluggable PDPs**:

1. **OPA (Open Policy Agent)**: Rule-based policies on trust headers and request attributes
2. **Trust Score Engine**: Real-time risk scoring based on delegation graph anomalies
3. **External PDPs**: Any system speaking standard authorization callout protocols (AuthZen, ext_authz)

**Decision Combiner**: Aggregates decisions from multiple PDPs (all must allow, or configurable quorum).

## 4. Design Details

### 4.1 Request Lifecycle

1. **Ingress Gateway**:
   - Extract principal identity from OAuth token
   - Stamp immutable trust headers (`x-principal-id`, `x-request-id`)
   - Query PDP: "Allow principal X to invoke system?"
   - Forward request with trust headers

2. **Agent Sidecar (Outbound)**:
   - Validate token via AuthBridge (credential verification)
   - Query PDP: "Allow agent A to invoke tool T on behalf of principal P?"
   - If allowed: mutate trust headers (`x-caller-id=A`, `x-trust-target=T`)
   - Emit trust-tagged span with delegation context
   - Forward request

3. **Tool Sidecar (Inbound)**:
   - Receive request with trust headers
   - Validate token via AuthBridge
   - Query PDP: "Allow this delegation chain to access tool T?"
   - Emit trust-tagged span (inbound hop)

4. **Tool Sidecar (Outbound → Resource)**:
   - Query PDP: "Allow tool T to access resource R given delegation context?"
   - Emit trust-tagged span
   - Forward to resource

### 4.2 Trust-Tagged Spans

Each sidecar emits OpenTelemetry spans with tags:

```json
{
  "trust.source": "agent-A",
  "trust.target": "tool-T",
  "trust.hop_kind": "invoke",
  "trust.run_id": "550e8400-e29b-41d4-a716-446655440000",
  "trust.principal_id": "user@example.com"
}
```

### 4.3 Lineage Service

Queries the trace backend and reconstructs the delegation DAG:
- Topologically ordered event list (causal chain)
- DAG with nodes (actors) and edges (delegations)
- Provenance queries: "Why did tool T access resource R?"
- Risk scoring: novel edges, depth anomalies, capability overreach

### 4.4 Integration with AuthBridge

**AuthBridge responsibilities** (unchanged):
- Token validation
- Audience verification
- Token exchange for downstream services

**AuthBroker PEP responsibilities** (new):
- Policy evaluation at request time
- Trust header propagation
- Span emission for lineage reconstruction

**Interaction**: AuthBridge performs credential verification. AuthBroker consumes the verified credential and uses it as input for authorization policy evaluation.

## 5. Open Design Questions

### 5.1 Policy Decision Sequencing

**Question**: Should PDP queries occur before or after token exchange?

**Options**:
- **Before**: Fail fast if policy denies, avoid unnecessary token exchange overhead
- **After**: Policy can use claims from exchanged token (e.g., scopes, roles from downstream service)

**Recommendation**: TBD (requires cross-team alignment)

### 5.2 Dynamic Descoping

**Question**: How should dynamic descoping be implemented?

**Options**:
- Modify token claims during exchange (requires Keycloak customization)
- Add descoping metadata to trust headers (interpreted by downstream services)
- Enforce descoping at PEP level (deny requests outside allowed scope)

**Recommendation**: TBD

### 5.3 Request Context for PDPs

**Question**: What request context should be available to PDPs?

**Candidates**:
- Trust headers (principal, caller, target, hop kind)
- Token claims (roles, scopes, audience)
- Request attributes (method, path, body hash)
- Historical context (has this delegation occurred before?)
- Runtime signals (trust score, anomaly flags)

**Recommendation**: TBD (define minimal required context + optional enrichment)

### 5.4 Multiple PDP Integration

**Question**: How should multiple PDPs be integrated?

**Options**:
- Sequential (query in order, short-circuit on deny)
- Parallel (query all, require all allow)
- Quorum (configurable N-of-M must allow)
- Priority (higher-priority PDP decision overrides lower)

**Recommendation**: Support pluggable decision combiners (start with "all must allow")

### 5.5 AuthZen Compatibility

**Question**: Should AuthBroker implement the AuthZen protocol for PDP queries?

**Benefit**: Standard protocol allows swapping PDPs without changing AuthBroker
**Tradeoff**: May require translation layer for existing PDPs (OPA, custom engines)

**Recommendation**: TBD

## 6. Alternatives Considered

### 6.1 Agent-Level Instrumentation

**Approach**: Require agents to call PDPs directly and emit lineage spans.

**Rejected because**:
- Agents cannot be trusted to enforce their own authorization
- Requires instrumenting every agent (high developer friction)
- Agents can lie about delegation context

### 6.2 Token-Only Authorization

**Approach**: Encode all authorization logic in token claims (roles, scopes).

**Rejected because**:
- Does not support request-level context (which tool is being invoked?)
- Cannot enforce delegation-specific policies (agent A → tool B allowed?)
- No visibility into delegation chains for auditability

### 6.3 Centralized Gateway

**Approach**: Single gateway performs all authorization and routing.

**Rejected because**:
- Single point of failure
- Does not scale for complex multi-hop delegation
- Cannot enforce policies at tool → resource boundary

## 7. Success Criteria

This proposal is successful if:

1. **Authorization policies** can restrict agent → tool and tool → resource delegations based on runtime context
2. **Delegation lineage** is captured automatically without instrumenting agents
3. **Existing identity infrastructure** (Keycloak, AuthBridge) continues to work unchanged
4. **PDPs are pluggable** (OPA, trust score engine, external systems)
5. **Policy decisions** can use trust headers, token claims, and historical context
6. **Agents cannot bypass** authorization by self-reporting delegation context

## 8. Next Steps

1. Align on answers to open design questions (§5)
2. Define standard PDP query interface (consider AuthZen)
3. Prototype AuthBroker PEP integration with AuthBridge
4. Implement trust header propagation in sidecars
5. Build lineage service integration with trace backend
6. Develop initial policy set for OPA and trust score engine

## 9. References

- **AuthZen**: https://openid.github.io/authzen/
- **OPA (Open Policy Agent)**: https://www.openpolicyagent.org/
- **OpenTelemetry**: https://opentelemetry.io/
- **Keycloak Token Exchange**: https://www.keycloak.org/docs/latest/securing_apps/#_token-exchange
