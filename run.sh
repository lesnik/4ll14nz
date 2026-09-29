#!/usr/bin/env bash
# One command, from nothing to a finished blue/green switch + rollback demo.
#   ./run.sh
# Requires: docker (running), kind, kubectl, helm.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib.sh"
cd "$ROOT"

CROSSPLANE_VERSION=1.20.13

for t in docker kind kubectl helm; do command -v "$t" >/dev/null || abort "$t not found"; done
docker info >/dev/null 2>&1 || abort "docker daemon not reachable"

# ---------------------------------------------------------------- 1. cluster
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  step "creating kind cluster $CLUSTER"
  kind create cluster --config cluster/kind.yaml --kubeconfig "$KUBECONFIG" --wait 120s
else
  kind export kubeconfig --name "$CLUSTER" --kubeconfig "$KUBECONFIG"
fi
pass "cluster ready ($(kubectl get nodes --no-headers | wc -l | tr -d ' ') node)"

# ------------------------------------------------------------- 2. crossplane
step "installing Crossplane $CROSSPLANE_VERSION"
helm repo add crossplane-stable https://charts.crossplane.io/stable >/dev/null 2>&1 || true
helm repo update crossplane-stable >/dev/null
helm upgrade --install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system --create-namespace \
  --version "$CROSSPLANE_VERSION" --wait --timeout 5m >/dev/null
pass "crossplane running"

step "installing provider-kubernetes and composition functions"
kubectl apply -f crossplane/providers.yaml >/dev/null
kubectl wait provider.pkg.crossplane.io/provider-kubernetes --for=condition=Healthy --timeout=300s >/dev/null
kubectl wait function.pkg.crossplane.io --all --for=condition=Healthy --timeout=300s >/dev/null
kubectl apply -f crossplane/provider-rbac.yaml -f crossplane/provider-config.yaml >/dev/null
pass "provider and functions healthy"

# -------------------------------------------------------------------- 3. api
step "installing the App API (XRD + Composition)"
kubectl apply -f api/xrd.yaml >/dev/null
kubectl wait xrd/xapps.demo.milan.dev --for=condition=Established --timeout=120s >/dev/null
kubectl wait xrd/xapps.demo.milan.dev --for=condition=Offered --timeout=120s >/dev/null
# On re-runs with a changed schema, Crossplane regenerates the CRD asynchronously;
# a claim applied before that lands gets its new fields pruned. Wait for a field
# from the current schema to be visible in the generated CRD.
wait_for "generated CRD to carry the current schema" 60 bash -c \
  "kubectl get crd apps.demo.milan.dev -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.blue.properties.env}' | grep -q additionalProperties" \
  || exit 1
kubectl apply -f api/composition.yaml >/dev/null
pass "App API available: kubectl explain app.spec"

# ------------------------------------------------------------------- 4. demo
kubectl -n "$NS" get pod probe >/dev/null 2>&1 || \
  kubectl -n "$NS" run probe --image=curlimages/curl:8.22.0 --restart=Never --command -- sleep infinity >/dev/null
kubectl -n "$NS" wait pod/probe --for=condition=Ready --timeout=120s >/dev/null

step "STEP 1  create the app: v1 in blue (live), v2 staged in green"
kubectl apply -f examples/app.yaml >/dev/null
kubectl -n "$NS" wait app/"$APP" --for=condition=Ready --timeout=300s >/dev/null
wait_for_http 60 || exit 1
pass "app ready, serving: $(serving)"

step "STEP 2  promote green (v2, healthy) - expect: promoted"
scripts/promote.sh green && rc=0 || rc=$?
[[ $rc -eq 0 ]] || abort "expected promotion, got exit $rc"
pass "now serving: $(serving)"

step "STEP 3  stage v3 into the free blue slot (this build is broken: reports unhealthy)"
kubectl apply -f examples/app-v3-broken.yaml >/dev/null

step "STEP 4  promote blue (v3, broken) - expect: automatic rollback to green"
scripts/promote.sh blue && rc=0 || rc=$?
[[ $rc -eq 10 ]] || abort "expected rollback (exit 10), got exit $rc"
pass "now serving: $(serving)"

echo
kubectl -n "$NS" get app "$APP" -o custom-columns='NAME:.metadata.name,ACTIVE:.spec.activeColor,SERVING:.status.servingColor,BLUE:.status.blue.version,BLUE_READY:.status.blue.ready,GREEN:.status.green.version,GREEN_READY:.status.green.ready,READY:.status.conditions[?(@.type=="Ready")].status'
echo
pass "demo complete: healthy release promoted, broken release rolled back"
echo "   export KUBECONFIG=$KUBECONFIG   # to poke around;  ./down.sh to tear down"
