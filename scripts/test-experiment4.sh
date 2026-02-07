#!/bin/bash
# Test Experiment 4: Trust Graph Decision Surface
# Tests: SQLite ingest, lazy ingestion, baseline learning, assessment scoring,
#        agent card registration, capability alignment

set -e

INGRESS_URL="${INGRESS_URL:-http://localhost:8080}"
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
check() {
    if [ "$1" = "true" ]; then pass "$2"; else fail "$2"; fi
}

echo "=== Trust Graph Experiment 4: Decision Surface ==="
echo ""

# -------------------------------------------------------
# Part 1: Agent Cards
# -------------------------------------------------------
echo "1. Agent Card Registration"

CARDS=$(curl -s "${INGRESS_URL}/agent-cards")
CARD_COUNT=$(echo "$CARDS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('total',0))" 2>/dev/null || echo 0)
check "$([ "$CARD_COUNT" -ge 4 ] && echo true)" "Loaded $CARD_COUNT agent cards (expected >= 4)"

# Check individual card lookup
CARD=$(curl -s "${INGRESS_URL}/agent-cards/agent:chat-agent")
HAS_DEPS=$(echo "$CARD" | python3 -c "
import json,sys
d=json.load(sys.stdin)
deps = d.get('dependencies',[])
print('true' if len(deps) == 3 and all(':' in dep for dep in deps) else 'false')
" 2>/dev/null || echo false)
check "$HAS_DEPS" "chat-agent card has 3 prefixed dependencies"

# Check short-name lookup
SHORT=$(curl -s "${INGRESS_URL}/agent-cards/read-agent")
SHORT_OK=$(echo "$SHORT" | python3 -c "
import json,sys; d=json.load(sys.stdin); print('true' if d.get('agent_id')=='agent:read-agent' else 'false')
" 2>/dev/null || echo false)
check "$SHORT_OK" "Short-name lookup (read-agent -> agent:read-agent)"

# Test POST registration
POST_RESULT=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"agent_id":"agent:test-e4","name":"test-e4","version":"0.1","capabilities":["test"],"dependencies":["resource:mock-database"]}' \
  "${INGRESS_URL}/agent-cards")
POST_OK=$(echo "$POST_RESULT" | python3 -c "
import json,sys; d=json.load(sys.stdin); print('true' if d.get('status')=='registered' else 'false')
" 2>/dev/null || echo false)
check "$POST_OK" "POST /agent-cards registers new card"

# Verify it appears in list
CARDS2=$(curl -s "${INGRESS_URL}/agent-cards")
HAS_NEW=$(echo "$CARDS2" | python3 -c "
import json,sys; d=json.load(sys.stdin)
ids = [c['agent_id'] for c in d.get('agent_cards',[])]
print('true' if 'agent:test-e4' in ids else 'false')
" 2>/dev/null || echo false)
check "$HAS_NEW" "New card appears in GET /agent-cards"

echo ""

# -------------------------------------------------------
# Part 2: Baseline Building + Assessment
# -------------------------------------------------------
echo "2. Baseline Building & Assessment Scoring"

# Clear the test card from SQLite so it doesn't interfere
POD=$(kubectl get pods -n workloads -l app=lineage-service -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
kubectl exec "$POD" -n workloads -- python3 -c "
import sqlite3
conn = sqlite3.connect('/data/lineage.db')
conn.execute(\"DELETE FROM agent_cards WHERE agent_id = 'agent:test-e4'\")
conn.commit(); conn.close()
" 2>/dev/null

# Send 3 identical multi-agent requests to build a strong baseline
echo "  Sending 3 multi-agent requests to build baseline..."
for i in 1 2 3; do
    curl -s -X POST -H "x-principal-id: baseline-user" -H "Content-Type: application/json" \
      -d '{"prompt": "show me sales and employee summary"}' \
      "${INGRESS_URL}/chat" > /dev/null
    sleep 2
done
echo "  Waiting for traces to propagate..."
sleep 8

# Get run_ids for baseline-user
RUN_IDS=$(curl -s "${INGRESS_URL}/lineage/all" | python3 -c "
import json,sys
d = json.load(sys.stdin)
runs = [r['run_id'] for r in d.get('runs',[]) if r.get('principal') == 'baseline-user']
print(' '.join(runs))
" 2>/dev/null)

RUN_COUNT=$(echo "$RUN_IDS" | wc -w | tr -d ' ')
check "$([ "$RUN_COUNT" -ge 3 ] && echo true)" "Found $RUN_COUNT baseline-user runs (expected >= 3)"

# Ingest all runs by querying their DAGs (triggers lazy ingest)
echo "  Triggering lazy ingest on all runs..."
for RID in $RUN_IDS; do
    curl -s "${INGRESS_URL}/lineage/${RID}/dag" > /dev/null
done
sleep 1

# Assess the latest run - should be ok or warn with multiple baselines
LATEST_RUN=$(echo "$RUN_IDS" | awk '{print $1}')
ASSESS=$(curl -s "${INGRESS_URL}/lineage/${LATEST_RUN}/assess")
VERDICT=$(echo "$ASSESS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('verdict',''))" 2>/dev/null)
SCORE=$(echo "$ASSESS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('risk_score',''))" 2>/dev/null)
BASELINE=$(echo "$ASSESS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('baseline_runs',''))" 2>/dev/null)
NOVEL_E=$(echo "$ASSESS" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('novel_edges',[])))" 2>/dev/null)

check "$([ "$BASELINE" -ge 2 ] && echo true)" "Assessment used $BASELINE baseline runs"
check "$([ "$NOVEL_E" -eq 0 ] && echo true)" "Zero novel edges for repeated behavior (got $NOVEL_E)"
echo "  Latest run verdict: $VERDICT (score=$SCORE)"

echo ""

# -------------------------------------------------------
# Part 3: Assessment Text Format
# -------------------------------------------------------
echo "3. Assessment Text Format"

ASSESS_TEXT=$(curl -s "${INGRESS_URL}/lineage/${LATEST_RUN}/assess?format=text")
HAS_HEADER=$(echo "$ASSESS_TEXT" | grep -c "TRUST ASSESSMENT" || true)
HAS_VERDICT=$(echo "$ASSESS_TEXT" | grep -c "Verdict:" || true)
HAS_CAP=$(echo "$ASSESS_TEXT" | grep -c "CAPABILITY ALIGNMENT" || true)
check "$([ "$HAS_HEADER" -gt 0 ] && echo true)" "Text format has TRUST ASSESSMENT header"
check "$([ "$HAS_VERDICT" -gt 0 ] && echo true)" "Text format has Verdict line"
check "$([ "$HAS_CAP" -gt 0 ] && echo true)" "Text format has CAPABILITY ALIGNMENT section"

echo ""

# -------------------------------------------------------
# Part 4: Capability Alignment
# -------------------------------------------------------
echo "4. Capability Alignment"

CAP_RESULTS=$(echo "$ASSESS" | python3 -c "
import json,sys
d = json.load(sys.stdin)
caps = d.get('capability_alignment', [])
statuses = {c['agent']: c['status'] for c in caps}
aligned = sum(1 for s in statuses.values() if s == 'aligned')
print(f'{len(caps)} {aligned}')
for agent, status in sorted(statuses.items()):
    print(f'  {agent}: {status}')
" 2>/dev/null)
TOTAL_AGENTS=$(echo "$CAP_RESULTS" | head -1 | awk '{print $1}')
ALIGNED_AGENTS=$(echo "$CAP_RESULTS" | head -1 | awk '{print $2}')
check "$([ "$TOTAL_AGENTS" -ge 3 ] && echo true)" "Capability check covers $TOTAL_AGENTS agents"
check "$([ "$ALIGNED_AGENTS" -eq "$TOTAL_AGENTS" ] && echo true)" "All $ALIGNED_AGENTS agents aligned with declared dependencies"
echo "$CAP_RESULTS" | tail -n +2

echo ""

# -------------------------------------------------------
# Part 5: SQLite-First Endpoints
# -------------------------------------------------------
echo "5. SQLite-First Endpoint Verification"

# DAG from SQLite
DAG=$(curl -s "${INGRESS_URL}/lineage/${LATEST_RUN}/dag")
DAG_SRC=$(echo "$DAG" | python3 -c "import json,sys; print(json.load(sys.stdin).get('source',''))" 2>/dev/null)
check "$([ "$DAG_SRC" = "sqlite" ] && echo true)" "DAG served from SQLite (source=$DAG_SRC)"

# Trust from SQLite
TRUST=$(curl -s "${INGRESS_URL}/lineage/${LATEST_RUN}/trust")
TRUST_SRC=$(echo "$TRUST" | python3 -c "import json,sys; print(json.load(sys.stdin).get('source',''))" 2>/dev/null)
check "$([ "$TRUST_SRC" = "sqlite" ] && echo true)" "Trust chain served from SQLite (source=$TRUST_SRC)"

# Explain from SQLite
EXPLAIN=$(curl -s "${INGRESS_URL}/lineage/${LATEST_RUN}/explain?node=resource:mock-database")
EXPLAIN_SRC=$(echo "$EXPLAIN" | python3 -c "import json,sys; print(json.load(sys.stdin).get('source',''))" 2>/dev/null)
check "$([ "$EXPLAIN_SRC" = "sqlite" ] && echo true)" "Explain served from SQLite (source=$EXPLAIN_SRC)"

echo ""

# -------------------------------------------------------
# Part 6: Novel Principal Detection
# -------------------------------------------------------
echo "6. Novel Principal Detection"

# Use a unique principal each test run to guarantee novelty
NOVEL_PRINCIPAL="outsider-$(date +%s)"
curl -s -X POST -H "x-principal-id: ${NOVEL_PRINCIPAL}" -H "Content-Type: application/json" \
  -d '{"prompt": "show me employees"}' \
  "${INGRESS_URL}/chat" > /dev/null
sleep 6

OUTSIDER_RUN=$(curl -s "${INGRESS_URL}/lineage/all" | python3 -c "
import json,sys
d = json.load(sys.stdin)
runs = [r['run_id'] for r in d.get('runs',[]) if '${NOVEL_PRINCIPAL}' in r.get('principal','')]
print(runs[0] if runs else 'NONE')
" 2>/dev/null)

if [ "$OUTSIDER_RUN" != "NONE" ]; then
    OUTSIDER_ASSESS=$(curl -s "${INGRESS_URL}/lineage/${OUTSIDER_RUN}/assess")
    OUTSIDER_NOVEL=$(echo "$OUTSIDER_ASSESS" | python3 -c "
import json,sys; d=json.load(sys.stdin)
novel = [e for e in d.get('novel_edges',[]) if 'outsider' in e.get('source','')]
print(len(novel))
" 2>/dev/null)
    OUTSIDER_SCORE=$(echo "$OUTSIDER_ASSESS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('risk_score',0))" 2>/dev/null)
    OUTSIDER_VERDICT=$(echo "$OUTSIDER_ASSESS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('verdict',''))" 2>/dev/null)
    check "$([ "$OUTSIDER_NOVEL" -ge 1 ] && echo true)" "Novel principal edge detected for ${NOVEL_PRINCIPAL} ($OUTSIDER_NOVEL novel)"
    echo "  ${NOVEL_PRINCIPAL}: verdict=$OUTSIDER_VERDICT score=$OUTSIDER_SCORE"
else
    fail "Could not find ${NOVEL_PRINCIPAL} run"
fi

echo ""

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo "=== Experiment 4 Test Summary ==="
echo ""
TOTAL=$((PASS+FAIL))
echo "  Passed: $PASS / $TOTAL"
if [ "$FAIL" -gt 0 ]; then
    echo "  Failed: $FAIL / $TOTAL"
fi
echo ""
echo "Endpoints tested:"
echo "  GET  /agent-cards"
echo "  GET  /agent-cards/{agent_id}"
echo "  POST /agent-cards"
echo "  GET  /lineage/{run_id}/assess?format=json|text"
echo "  GET  /lineage/{run_id}/dag    (SQLite-first)"
echo "  GET  /lineage/{run_id}/trust  (SQLite-first)"
echo "  GET  /lineage/{run_id}/explain (SQLite-first)"
echo ""
