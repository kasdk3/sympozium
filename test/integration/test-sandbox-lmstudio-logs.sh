#!/usr/bin/env bash
# Integration test: Sandbox + LM Studio — controller log verification.
#
# Creates a SympoziumInstance with sandboxing enabled and LM Studio as the
# provider, submits a simple AgentRun, then verifies the controller manager
# emits the expected sandbox-lifecycle log lines.
#
# Prerequisites:
#   - KIND cluster running with sympozium deployed
#   - Agent Sandbox CRDs installed (apps.kubernetes.io/v1alpha1)
#   - No real LM Studio endpoint required (test validates CR creation, not LLM execution)

set -euo pipefail

NAMESPACE="${TEST_NAMESPACE:-default}"
SYSTEM_NS="${SYMPOZIUM_NAMESPACE:-sympozium-system}"
TIMEOUT="${TEST_TIMEOUT:-60}"

# Fully-qualified resource name to avoid ambiguity with agents.x-k8s.io CRDs.
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
INSTANCE="inttest-sb-lms-${SUFFIX}"
RUN_NAME="inttest-sb-lms-run-${SUFFIX}"

cleanup() {
  info "Cleaning up sandbox-lmstudio test resources..."
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

wait_for_field_notempty() {
  local resource="$1" name="$2" jsonpath="$3" label="$4"
  local elapsed=0
  while [[ "$elapsed" -lt "$TIMEOUT" ]]; do
    val="$(kubectl get "$resource" "$name" -n "$NAMESPACE" -o jsonpath="$jsonpath" 2>/dev/null || true)"
    if [[ -n "$val" ]]; then
      printf "%s" "$val"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  fail "${label}: timed out waiting for ${jsonpath} to be non-empty"
  return 1
}

# extract_sandbox_field uses python3 to safely extract a nested field from the
# Sandbox CR JSON. This avoids jsonpath issues with unstructured CRDs.
extract_sandbox_field() {
  local sb_json="$1" python_expr="$2"
  echo "$sb_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
${python_expr}
" 2>/dev/null || true
}

# ── Preflight ─────────────────────────────────────────────────────────────────

info "Running Sandbox + LM Studio controller-log test in namespace '${NAMESPACE}'"

# Verify agent-sandbox CRDs are present.
for crd in sandboxes.agents.x-k8s.io sandboxclaims.agents.x-k8s.io sandboxwarmpools.agents.x-k8s.io; do
  if kubectl get crd "$crd" >/dev/null 2>&1; then
    pass "CRD ${crd} installed"
  else
    fail "CRD ${crd} missing"
    exit 1
  fi
done

# Verify controller has agent-sandbox support enabled.
controller_logs="$(kubectl logs deployment/sympozium-controller-manager -n "$SYSTEM_NS" 2>/dev/null || true)"
if echo "$controller_logs" | grep -q "Agent Sandbox CRD support enabled"; then
  pass "Controller has agent-sandbox support enabled"
else
  fail "Controller does not report agent-sandbox support — check CRDs and AGENT_SANDBOX_ENABLED env"
  echo "$controller_logs" | grep -i "sandbox\|setup" | tail -5
  exit 1
fi

# Capture the current log length so we only inspect new lines later.
LOG_BASELINE="$(kubectl logs deployment/sympozium-controller-manager -n "$SYSTEM_NS" 2>/dev/null | wc -l | tr -d ' ')"

# ── Setup: Instance + Secret ──────────────────────────────────────────────────

info "Creating LM Studio instance with sandbox enabled"

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
      model: llama-3.2-1b
      baseURL: "http://host.docker.internal:1234/v1"
      agentSandbox:
        enabled: true
        runtimeClass: gvisor
  authRefs:
    - provider: lm-studio
      secret: ${INSTANCE}-lms-key
EOF
pass "Instance '${INSTANCE}' created (provider=lm-studio, sandbox=on)"

# ── Test 1: Submit AgentRun and verify Sandbox CR creation ────────────────────

info "Test 1: AgentRun creates Sandbox CR (not a Job)"

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
  sessionKey: "test-sb-lms-${SUFFIX}"
  task: "Say hello world"
  model:
    provider: lm-studio
    model: llama-3.2-1b
    baseURL: "http://host.docker.internal:1234/v1"
    authSecretRef: ${INSTANCE}-lms-key
  agentSandbox:
    enabled: true
    runtimeClass: gvisor
EOF

sb_name="$(wait_for_field_notempty agentrun "${RUN_NAME}" '{.status.sandboxName}' "Test 1: sandboxName" || true)"
if [[ -n "$sb_name" ]]; then
  pass "Test 1: Sandbox CR created — status.sandboxName = ${sb_name}"
else
  fail "Test 1: sandboxName never appeared on AgentRun status"
fi

# Verify no Job was created.
job_name="$(kubectl get agentrun "${RUN_NAME}" -n "$NAMESPACE" -o jsonpath='{.status.jobName}' 2>/dev/null || true)"
if [[ -z "$job_name" ]]; then
  pass "Test 1: No Job created (correct — sandbox mode)"
else
  fail "Test 1: Job '${job_name}' was unexpectedly created"
fi

# ── Fetch Sandbox CR JSON (used by Tests 2 & 3) ──────────────────────────────

sb_json=""
if [[ -n "$sb_name" ]]; then
  sb_json="$(kubectl get "$SANDBOX_RESOURCE" "${sb_name}" -n "$NAMESPACE" -o json 2>/dev/null || true)"
fi

# ── Test 2: Sandbox CR metadata ──────────────────────────────────────────────

info "Test 2: Sandbox CR metadata"

if [[ -n "$sb_json" ]]; then
  sb_runtime="$(extract_sandbox_field "$sb_json" "print(data.get('spec',{}).get('podTemplate',{}).get('spec',{}).get('runtimeClassName',''))")"
  if [[ "$sb_runtime" == "gvisor" ]]; then
    pass "Test 2: runtimeClassName = gvisor"
  else
    fail "Test 2: runtimeClassName = '${sb_runtime}', expected 'gvisor'"
  fi

  sb_owner="$(extract_sandbox_field "$sb_json" "
refs = data.get('metadata',{}).get('ownerReferences',[])
print(refs[0]['kind'] if refs else '')
")"
  if [[ "$sb_owner" == "AgentRun" ]]; then
    pass "Test 2: ownerReference.kind = AgentRun"
  else
    fail "Test 2: ownerReference.kind = '${sb_owner}', expected 'AgentRun'"
  fi

  sb_label="$(extract_sandbox_field "$sb_json" "print(data.get('metadata',{}).get('labels',{}).get('sympozium.ai/instance',''))")"
  if [[ "$sb_label" == "${INSTANCE}" ]]; then
    pass "Test 2: instance label = ${INSTANCE}"
  else
    fail "Test 2: instance label = '${sb_label}', expected '${INSTANCE}'"
  fi
else
  fail "Test 2: skipped — could not fetch Sandbox CR"
fi

# ── Test 3: Verify provider env on the agent container ───────────────────────

info "Test 3: Agent container has LM Studio provider config"

if [[ -n "$sb_json" ]]; then
  extract_env() {
    local var_name="$1"
    extract_sandbox_field "$sb_json" "
containers = data.get('spec',{}).get('podTemplate',{}).get('spec',{}).get('containers',[])
for c in containers:
    if c.get('name') == 'agent':
        for e in c.get('env',[]):
            if e.get('name') == '${var_name}':
                print(e.get('value',''))
                sys.exit(0)
print('')
"
  }

  provider_env="$(extract_env MODEL_PROVIDER)"
  if [[ "$provider_env" == "lm-studio" ]]; then
    pass "Test 3: MODEL_PROVIDER = lm-studio"
  else
    fail "Test 3: MODEL_PROVIDER = '${provider_env}', expected 'lm-studio'"
  fi

  base_url_env="$(extract_env MODEL_BASE_URL)"
  if [[ "$base_url_env" == *"1234"* ]]; then
    pass "Test 3: MODEL_BASE_URL contains LM Studio port (${base_url_env})"
  else
    fail "Test 3: MODEL_BASE_URL = '${base_url_env}', expected URL with port 1234"
  fi
else
  fail "Test 3: skipped — could not fetch Sandbox CR"
fi

# ── Test 4: Controller manager logs ──────────────────────────────────────────

info "Test 4: Controller manager emitted sandbox lifecycle logs"

# Give the controller a moment to flush reconciliation logs.
sleep 3

# Fetch only the new log lines since the test started.
new_logs="$(kubectl logs deployment/sympozium-controller-manager -n "$SYSTEM_NS" 2>/dev/null | tail -n +"$((LOG_BASELINE + 1))")"

# 4a: "Creating Agent Sandbox CR for AgentRun"
if echo "$new_logs" | grep -q "Creating Agent Sandbox CR for AgentRun"; then
  pass "Test 4a: log — 'Creating Agent Sandbox CR for AgentRun'"
else
  fail "Test 4a: missing log — 'Creating Agent Sandbox CR for AgentRun'"
fi

# 4b: "Checking Agent Sandbox CR status"
if echo "$new_logs" | grep -q "Checking Agent Sandbox CR status"; then
  pass "Test 4b: log — 'Checking Agent Sandbox CR status'"
else
  # The status check may not have fired yet if the sandbox hasn't transitioned.
  # Wait a bit and retry once.
  sleep 5
  new_logs="$(kubectl logs deployment/sympozium-controller-manager -n "$SYSTEM_NS" 2>/dev/null | tail -n +"$((LOG_BASELINE + 1))")"
  if echo "$new_logs" | grep -q "Checking Agent Sandbox CR status"; then
    pass "Test 4b: log — 'Checking Agent Sandbox CR status'"
  else
    fail "Test 4b: missing log — 'Checking Agent Sandbox CR status'"
  fi
fi

# 4c: Verify the run name appears in logs (structured logging includes the AgentRun name).
if echo "$new_logs" | grep -q "${RUN_NAME}"; then
  pass "Test 4c: log references AgentRun '${RUN_NAME}'"
else
  fail "Test 4c: AgentRun name '${RUN_NAME}' not found in controller logs"
fi

# 4d: No unexpected error-level logs related to this run.
# Filter out transient "object has been modified" conflict errors — these are
# benign optimistic-locking retries that the controller handles automatically.
error_lines="$(echo "$new_logs" \
  | grep -i '"level":"error"\|ERROR' \
  | grep -i "${INSTANCE}\|${RUN_NAME}" \
  | grep -v "the object has been modified" \
  || true)"
if [[ -z "$error_lines" ]]; then
  pass "Test 4d: no unexpected ERROR-level logs for this run"
else
  fail "Test 4d: unexpected errors in controller logs:"
  echo "$error_lines" | head -5
fi

# ── Test 5: Dump new controller logs for debugging ────────────────────────────

info "Test 5: Controller log excerpt (sandbox-related lines)"
echo "$new_logs" | grep -i "sandbox\|${RUN_NAME}\|${INSTANCE}" | tail -20 || true
echo ""

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
if [[ "$EXIT_CODE" -eq 0 ]]; then
  pass "All sandbox + LM Studio controller-log tests passed"
else
  fail "Some tests failed"
fi
exit "$EXIT_CODE"
