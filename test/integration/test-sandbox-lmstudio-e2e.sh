#!/usr/bin/env bash
# Integration test: End-to-end Agent Sandbox + LM Studio lifecycle.
#
# Validates that an AgentRun with sandboxing enabled goes through the full
# lifecycle: Pending → Running (Sandbox CR) → Succeeded, with the agent
# actually executing against a real LM Studio endpoint and producing a result.
#
# This removes ambiguity about whether sandbox mode actually works end-to-end,
# not just that the right CRs get created.
#
# Prerequisites:
#   - KIND cluster running with sympozium deployed
#   - Agent Sandbox CRDs installed + agent-sandbox-controller-0 running
#   - LM Studio reachable at host.docker.internal:1234
#   - At least one model loaded in LM Studio

set -euo pipefail

NAMESPACE="${TEST_NAMESPACE:-default}"
SYSTEM_NS="${SYMPOZIUM_NAMESPACE:-sympozium-system}"
TIMEOUT="${TEST_TIMEOUT:-300}"

# Fully-qualified to avoid ambiguity with agents.x-k8s.io CRDs.
SANDBOX_RESOURCE="sandboxes.agents.x-k8s.io"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓ $*${NC}"; }
fail() { echo -e "${RED}✗ $*${NC}"; EXIT_CODE=1; }
info() { echo -e "${YELLOW}● $*${NC}"; }

EXIT_CODE=0
SUFFIX="$(date +%s)"
INSTANCE="e2e-sb-lms-${SUFFIX}"
RUN_NAME="e2e-sb-lms-run-${SUFFIX}"

cleanup() {
  info "Cleaning up e2e test resources..."
  kubectl delete agentrun "${RUN_NAME}" \
    -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete sympoziuminstance "${INSTANCE}" \
    -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete "$SANDBOX_RESOURCE" -n "$NAMESPACE" -l "sympozium.ai/instance=${INSTANCE}" \
    --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete secret "${INSTANCE}-lms-key" \
    -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete configmap -n "$NAMESPACE" -l "sympozium.ai/instance=${INSTANCE}" \
    --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_for_field() {
  local resource="$1" name="$2" jsonpath="$3" expected="$4" label="$5"
  local elapsed=0
  while [[ "$elapsed" -lt "$TIMEOUT" ]]; do
    val="$(kubectl get "$resource" "$name" -n "$NAMESPACE" -o jsonpath="$jsonpath" 2>/dev/null || true)"
    if [[ "$val" == "$expected" ]]; then
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  fail "${label}: timed out waiting for ${jsonpath}=${expected} (got: ${val:-<empty>})"
  return 1
}

wait_for_field_notempty() {
  local resource="$1" name="$2" jsonpath="$3" label="$4"
  local elapsed=0
  while [[ "$elapsed" -lt "$TIMEOUT" ]]; do
    val="$(kubectl get "$resource" "$name" -n "$NAMESPACE" -o jsonpath="$jsonpath" 2>/dev/null || true)"
    if [[ -n "$val" ]]; then
      printf "%s" "$val"
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  fail "${label}: timed out waiting for ${jsonpath} to be non-empty"
  return 1
}

extract_sandbox_field() {
  local sb_json="$1" python_expr="$2"
  echo "$sb_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
${python_expr}
" 2>/dev/null || true
}

# ── Preflight ─────────────────────────────────────────────────────────────────

info "Running end-to-end Sandbox + LM Studio test in namespace '${NAMESPACE}'"

# 1. Agent Sandbox CRDs.
for crd in sandboxes.agents.x-k8s.io sandboxclaims.agents.x-k8s.io; do
  kubectl get crd "$crd" >/dev/null 2>&1 && pass "CRD ${crd} installed" || { fail "CRD ${crd} missing"; exit 1; }
done

# 2. Agent Sandbox controller is running.
sb_ctrl_ready="$(kubectl get pod agent-sandbox-controller-0 -n agent-sandbox-system \
  -o jsonpath='{.status.phase}' 2>/dev/null || true)"
if [[ "$sb_ctrl_ready" == "Running" ]]; then
  pass "agent-sandbox-controller-0 is Running"
else
  fail "agent-sandbox-controller-0 not running (phase=${sb_ctrl_ready:-not found})"
  exit 1
fi

# 3. Sympozium controller has sandbox support.
controller_logs="$(kubectl logs deployment/sympozium-controller-manager -n "$SYSTEM_NS" 2>/dev/null || true)"
if echo "$controller_logs" | grep -q "Agent Sandbox CRD support enabled"; then
  pass "Sympozium controller has sandbox support enabled"
else
  fail "Sympozium controller missing sandbox support"
  exit 1
fi

# 4. LM Studio is reachable from inside the cluster.
# The kubectl --rm -i output appends a "pod ... deleted" line after the JSON,
# so we use python3 with raw_decode to extract just the first JSON object.
lms_raw="$(kubectl run "e2e-lms-probe-${SUFFIX}" --rm -i --restart=Never \
  --image=curlimages/curl -- curl -s --connect-timeout 5 \
  http://host.docker.internal:1234/v1/models 2>/dev/null || true)"
LMS_MODEL="$(echo "$lms_raw" | python3 -c "
import sys, json
raw = sys.stdin.read()
# Find the first JSON object in the output.
start = raw.index('{')
data, _ = json.JSONDecoder().raw_decode(raw, start)
models = [m['id'] for m in data.get('data',[]) if 'embed' not in m['id'].lower()]
prefer = ['nano', 'lite', 'mini', 'small', '1b', '3b', '4b']
for hint in prefer:
    for m in models:
        if hint in m.lower():
            print(m); sys.exit(0)
print(models[0] if models else '')
" 2>/dev/null || true)"
if [[ -n "$LMS_MODEL" ]]; then
  pass "LM Studio reachable — using model '${LMS_MODEL}'"
else
  fail "LM Studio not reachable or no non-embedding models found"
  exit 1
fi

# Ensure the NetworkPolicy allows egress to LM Studio's port.
# The default sympozium-agent-allow-egress only permits standard provider
# ports (443, 11434). LM Studio runs on 1234 by default.
kubectl get networkpolicy sympozium-agent-allow-egress -n "$NAMESPACE" >/dev/null 2>&1 && {
  if ! kubectl get networkpolicy sympozium-agent-allow-egress -n "$NAMESPACE" \
      -o jsonpath='{.spec.egress[*].ports[*].port}' 2>/dev/null | grep -q 1234; then
    kubectl patch networkpolicy sympozium-agent-allow-egress -n "$NAMESPACE" --type='json' \
      -p='[{"op":"add","path":"/spec/egress/-","value":{"ports":[{"port":1234,"protocol":"TCP"}]}}]' >/dev/null 2>&1
    pass "Patched NetworkPolicy to allow egress on port 1234"
  fi
}

# Capture log baseline.
LOG_BASELINE="$(kubectl logs deployment/sympozium-controller-manager -n "$SYSTEM_NS" 2>/dev/null | wc -l | tr -d ' ')"

# ── Setup ─────────────────────────────────────────────────────────────────────

info "Creating instance and submitting AgentRun"

kubectl create secret generic "${INSTANCE}-lms-key" \
  --from-literal=API_KEY=lm-studio-no-key-needed \
  -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: sympozium.ai/v1alpha1
kind: SympoziumInstance
metadata:
  name: ${INSTANCE}
  namespace: ${NAMESPACE}
spec:
  agents:
    default:
      model: ${LMS_MODEL}
      baseURL: "http://host.docker.internal:1234/v1"
      agentSandbox:
        enabled: true
  authRefs:
    - provider: lm-studio
      secret: ${INSTANCE}-lms-key
EOF

cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: sympozium.ai/v1alpha1
kind: AgentRun
metadata:
  name: ${RUN_NAME}
  namespace: ${NAMESPACE}
  labels:
    sympozium.ai/instance: ${INSTANCE}
    sympozium.ai/component: agent-run
spec:
  instanceRef: ${INSTANCE}
  agentId: default
  sessionKey: "e2e-sb-lms-${SUFFIX}"
  task: "Reply with exactly: SANDBOX_OK"
  model:
    provider: lm-studio
    model: ${LMS_MODEL}
    baseURL: "http://host.docker.internal:1234/v1"
    authSecretRef: ${INSTANCE}-lms-key
  agentSandbox:
    enabled: true
EOF
pass "AgentRun '${RUN_NAME}' submitted (model=${LMS_MODEL})"

# ── Test 1: Sandbox CR created ────────────────────────────────────────────────

info "Test 1: Sandbox CR created"

sb_name="$(wait_for_field_notempty agentrun "${RUN_NAME}" '{.status.sandboxName}' "Test 1: sandboxName" || true)"
if [[ -n "$sb_name" ]]; then
  pass "Test 1: status.sandboxName = ${sb_name}"
else
  fail "Test 1: sandboxName never set"
fi

# ── Test 2: Sandbox CR transitions to Running ────────────────────────────────

info "Test 2: Sandbox CR becomes Ready (upstream uses conditions, not phase)"

if [[ -n "$sb_name" ]]; then
  elapsed=0
  sb_ready=""
  while [[ "$elapsed" -lt "$TIMEOUT" ]]; do
    # The upstream sandbox controller uses status.conditions with a "Ready" type.
    sb_ready="$(kubectl get "$SANDBOX_RESOURCE" "${sb_name}" -n "$NAMESPACE" -o json 2>/dev/null \
      | python3 -c "
import sys, json
data = json.load(sys.stdin)
for c in data.get('status',{}).get('conditions',[]):
    if c.get('type') == 'Ready':
        print(c.get('status',''))
        sys.exit(0)
print('')
" 2>/dev/null || true)"
    if [[ "$sb_ready" == "True" ]]; then
      break
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  if [[ "$sb_ready" == "True" ]]; then
    pass "Test 2: Sandbox Ready condition = True"
  else
    fail "Test 2: Sandbox Ready condition = '${sb_ready}', expected 'True'"
    # Dump the conditions for debugging.
    kubectl get "$SANDBOX_RESOURCE" "${sb_name}" -n "$NAMESPACE" \
      -o jsonpath='{.status.conditions}' 2>/dev/null | head -c 500 || true
    echo ""
  fi
else
  fail "Test 2: skipped — no sandbox name"
fi

# ── Test 3: Pod is scheduled and runs inside sandbox ──────────────────────────

info "Test 3: Agent pod is running inside sandbox"

# The upstream sandbox controller creates a pod with the same name as the
# Sandbox CR. Our controller sets podName = sandboxName.
pod_name="$(wait_for_field_notempty agentrun "${RUN_NAME}" '{.status.podName}' "Test 3: podName" || true)"
if [[ -n "$pod_name" ]]; then
  pass "Test 3: status.podName = ${pod_name}"

  # Wait for the pod to actually exist and start.
  elapsed=0
  pod_phase=""
  while [[ "$elapsed" -lt "$TIMEOUT" ]]; do
    pod_phase="$(kubectl get pod "${pod_name}" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ -n "$pod_phase" ]]; then
      break
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  if [[ -n "$pod_phase" ]]; then
    pass "Test 3: Pod exists (phase=${pod_phase})"
  else
    fail "Test 3: Pod '${pod_name}' not found"
  fi
else
  fail "Test 3: podName never set on AgentRun status"
fi

# ── Test 4: AgentRun reaches terminal phase (Succeeded or Failed) ─────────────

info "Test 4: AgentRun reaches terminal phase"

terminal_phase=""
elapsed=0
while [[ "$elapsed" -lt "$TIMEOUT" ]]; do
  phase="$(kubectl get agentrun "${RUN_NAME}" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]]; then
    terminal_phase="$phase"
    break
  fi
  sleep 3
  elapsed=$((elapsed + 3))
done

if [[ "$terminal_phase" == "Succeeded" ]]; then
  pass "Test 4: AgentRun phase = Succeeded"
elif [[ "$terminal_phase" == "Failed" ]]; then
  run_error="$(kubectl get agentrun "${RUN_NAME}" -n "$NAMESPACE" -o jsonpath='{.status.error}' 2>/dev/null || true)"
  fail "Test 4: AgentRun phase = Failed (error: ${run_error})"
else
  fail "Test 4: AgentRun never reached terminal phase (last phase: ${phase:-<empty>})"
fi

# ── Test 5: Result and token usage populated ──────────────────────────────────

info "Test 5: Result and metrics"

if [[ "$terminal_phase" == "Succeeded" ]]; then
  result="$(kubectl get agentrun "${RUN_NAME}" -n "$NAMESPACE" -o jsonpath='{.status.result}' 2>/dev/null || true)"
  if [[ -n "$result" ]]; then
    pass "Test 5a: status.result is populated (${#result} chars)"
    # Check if the model followed the instruction.
    if echo "$result" | grep -qi "SANDBOX_OK"; then
      pass "Test 5a: Result contains 'SANDBOX_OK' — model followed instructions"
    else
      info "Test 5a: Result does not contain 'SANDBOX_OK' (model may have elaborated): $(echo "$result" | head -c 120)"
    fi
  else
    fail "Test 5a: status.result is empty"
  fi

  completed_at="$(kubectl get agentrun "${RUN_NAME}" -n "$NAMESPACE" -o jsonpath='{.status.completedAt}' 2>/dev/null || true)"
  if [[ -n "$completed_at" ]]; then
    pass "Test 5b: status.completedAt = ${completed_at}"
  else
    fail "Test 5b: status.completedAt is empty"
  fi

  input_tokens="$(kubectl get agentrun "${RUN_NAME}" -n "$NAMESPACE" -o jsonpath='{.status.tokenUsage.inputTokens}' 2>/dev/null || true)"
  output_tokens="$(kubectl get agentrun "${RUN_NAME}" -n "$NAMESPACE" -o jsonpath='{.status.tokenUsage.outputTokens}' 2>/dev/null || true)"
  if [[ -n "$input_tokens" && "$input_tokens" -gt 0 ]]; then
    pass "Test 5c: tokenUsage.inputTokens = ${input_tokens}"
  else
    info "Test 5c: tokenUsage.inputTokens empty (LM Studio may not report usage)"
  fi
  if [[ -n "$output_tokens" && "$output_tokens" -gt 0 ]]; then
    pass "Test 5c: tokenUsage.outputTokens = ${output_tokens}"
  else
    info "Test 5c: tokenUsage.outputTokens empty (LM Studio may not report usage)"
  fi
else
  fail "Test 5: skipped — run did not succeed"
fi

# ── Test 6: Sandbox CR also reached terminal phase ────────────────────────────

info "Test 6: Sandbox pod reached terminal state"

# The upstream sandbox controller doesn't set a terminal "phase" — we check
# the pod directly since that's what the Sympozium controller does.
if [[ -n "$pod_name" ]]; then
  pod_final_phase="$(kubectl get pod "${pod_name}" -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "$pod_final_phase" == "Succeeded" ]]; then
    pass "Test 6: Sandbox pod final phase = Succeeded"
  elif [[ "$pod_final_phase" == "Failed" ]]; then
    fail "Test 6: Sandbox pod final phase = Failed"
  else
    info "Test 6: Sandbox pod phase = '${pod_final_phase}' (may still be terminating)"
  fi
else
  fail "Test 6: skipped — no pod name"
fi

# ── Test 7: Controller logs show full lifecycle ───────────────────────────────

info "Test 7: Controller logs show full sandbox lifecycle"

new_logs="$(kubectl logs deployment/sympozium-controller-manager -n "$SYSTEM_NS" 2>/dev/null | tail -n +"$((LOG_BASELINE + 1))")"

# 7a: Creation.
if echo "$new_logs" | grep -q "Creating Agent Sandbox CR for AgentRun"; then
  pass "Test 7a: log — 'Creating Agent Sandbox CR for AgentRun'"
else
  fail "Test 7a: missing creation log"
fi

# 7b: Status polling.
if echo "$new_logs" | grep -q "Checking Agent Sandbox CR status"; then
  pass "Test 7b: log — 'Checking Agent Sandbox CR status'"
else
  fail "Test 7b: missing status-check log"
fi

# 7c: Completion.
if echo "$new_logs" | grep -q "Agent Sandbox completed successfully"; then
  pass "Test 7c: log — 'Agent Sandbox completed successfully'"
else
  fail "Test 7c: missing completion log"
fi

# 7d: Token usage extraction (if available).
if echo "$new_logs" | grep -q "extracted token usage"; then
  pass "Test 7d: log — 'extracted token usage'"
else
  info "Test 7d: no 'extracted token usage' log (LM Studio may not report usage)"
fi

# 7e: No unexpected errors.
error_lines="$(echo "$new_logs" \
  | grep -i '"level":"error"\|ERROR' \
  | grep -i "${INSTANCE}\|${RUN_NAME}" \
  | grep -v "the object has been modified" \
  || true)"
if [[ -z "$error_lines" ]]; then
  pass "Test 7e: no unexpected errors in controller logs"
else
  fail "Test 7e: unexpected errors:"
  echo "$error_lines" | head -5
fi

# ── Test 8: Agent pod logs contain result marker ──────────────────────────────

info "Test 8: Agent pod emitted structured result"

if [[ -n "$pod_name" ]]; then
  agent_logs="$(kubectl logs "${pod_name}" -n "$NAMESPACE" -c agent 2>/dev/null || true)"
  if echo "$agent_logs" | grep -q "__SYMPOZIUM_RESULT__"; then
    pass "Test 8: __SYMPOZIUM_RESULT__ marker found in agent pod logs"
  else
    fail "Test 8: __SYMPOZIUM_RESULT__ marker not found in agent pod logs"
  fi

  if echo "$agent_logs" | grep -q "agent-runner finished successfully"; then
    pass "Test 8: agent-runner exited successfully"
  else
    fail "Test 8: agent-runner did not finish successfully"
    echo "$agent_logs" | tail -5
  fi
else
  fail "Test 8: skipped — no pod name"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "─── Controller log excerpt ───"
echo "$new_logs" | grep -i "sandbox\|${RUN_NAME}" | tail -15 || true
echo ""

if [[ "$EXIT_CODE" -eq 0 ]]; then
  pass "All end-to-end sandbox + LM Studio tests passed"
else
  fail "Some tests failed"
fi
exit "$EXIT_CODE"
