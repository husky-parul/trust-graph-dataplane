#!/bin/bash
# Test the chat-agent multi-agent orchestration (Experiment 2)

set -e

echo "=== Trust Graph Experiment 2: Chat Agent Router ==="
echo ""

# Test 1: Sales query
echo "1. Testing sales query..."
echo '   POST /chat {"prompt": "Show me all sales data"}'
curl -s -X POST -H "x-principal-id: claude" -H "Content-Type: application/json" \
  -d '{"prompt": "Show me all sales data"}' \
  http://localhost:8080/chat | jq .

echo ""
sleep 1

# Test 2: Employee query
echo "2. Testing employee query..."
echo '   POST /chat {"prompt": "List all employees"}'
curl -s -X POST -H "x-principal-id: claude" -H "Content-Type: application/json" \
  -d '{"prompt": "List all employees"}' \
  http://localhost:8080/chat | jq .

echo ""
sleep 1

# Test 3: Salary summary
echo "3. Testing salary summary..."
echo '   POST /chat {"prompt": "What is the average salary?"}'
curl -s -X POST -H "x-principal-id: claude" -H "Content-Type: application/json" \
  -d '{"prompt": "What is the average salary?"}' \
  http://localhost:8080/chat | jq .

echo ""
sleep 1

# Test 4: Multi-agent query (should call multiple agents)
echo "4. Testing multi-agent query (sales + employee + salary)..."
echo '   POST /chat {"prompt": "Show me all employees and their sales with salary summary"}'
curl -s -X POST -H "x-principal-id: claude" -H "Content-Type: application/json" \
  -d '{"prompt": "Show me all employees and their sales with salary summary"}' \
  http://localhost:8080/chat | jq .

echo ""
sleep 2

# Test 5: Query lineage
echo "5. Checking recent lineage runs..."
curl -s "http://localhost:8080/lineage/all?format=text" | head -20

echo ""
echo "=== Test Complete ==="
echo ""
echo "Check Jaeger UI for trace lineage:"
echo "  http://localhost:16686"
echo ""
echo "Query specific lineage with:"
echo "  curl http://localhost:8080/lineage/<run_id>?format=text"
