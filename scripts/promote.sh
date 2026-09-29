#!/usr/bin/env bash
#
# (C) AllSet DevOps, s.r.o.
#
# The release automation. Switches the App to <color> and decides, on its own,
# whether to keep the switch or roll it back.
#
#   promote.sh <blue|green>
#
# Exit codes:  0 promoted   10 rolled back   20 aborted before switching
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TARGET=${1:?usage: promote.sh <blue|green>}
SMOKE_REQUESTS=${SMOKE_REQUESTS:-10}

CURRENT=$(app_field .spec.activeColor)
[[ "$CURRENT" == "$TARGET" ]] && { pass "$APP already serving $TARGET"; exit 0; }
step "promote: $CURRENT -> $TARGET"

# Gate 1: the target slot must be fully rolled out *at the version the claim
# currently asks for* before it gets any traffic. Comparing the observed version
# (from the real Deployment) with the desired one (from the claim spec) closes
# the window where status.ready is still true from the previous release.
WANT=$(app_field .spec.$TARGET.version)
slot_ready() {
  [[ "$(app_field .status.$TARGET.version)" == "$WANT" && "$(app_field .status.$TARGET.ready)" == true ]]
}
if ! wait_for "slot $TARGET ready at version $WANT" "${GATE_TIMEOUT:-120}" slot_ready; then
  notice "DECISION: abort, $TARGET never became ready at $WANT; traffic stays on $CURRENT"
  exit 20
fi
pass "slot $TARGET is fully rolled out at version $WANT"

switch_to() {
  local color=$1
  kubectl -n "$NS" patch app "$APP" --type merge -p "{\"spec\":{\"activeColor\":\"$color\"}}" >/dev/null
  # status.servingColor is read from the Service in the cluster, so it only changes once the switch is applied
  wait_for "Service to point at $color" 120 \
    bash -c "[[ \"\$(kubectl -n $NS get app $APP -o jsonpath='{.status.servingColor}')\" == $color ]]" \
    || abort "composition never switched the Service to $color"
  sleep 3   # let endpoints/kube-proxy settle
}

# Gate 2: after the switch, the app's own health endpoint must answer 200 over
# real Service traffic. Prints the number of failed requests; progress goes to stderr.
smoke() {
  local failures=0 res code body
  for i in $(seq 1 "$SMOKE_REQUESTS"); do
    res=$(http_get /healthz); code=${res%% *}; body=${res#* }
    if [[ "$code" != "200" ]]; then failures=$((failures + 1)); fi
    printf '    smoke %2d/%d: HTTP %s  %s\n' "$i" "$SMOKE_REQUESTS" "${code:-000}" "$body" >&2
    sleep 0.5
  done
  echo "$failures"
}

switch_to "$TARGET"
pass "traffic switched to $TARGET, now answering: $(serving)"
step "smoke test: GET /healthz x$SMOKE_REQUESTS"
failed=$(smoke)

if [[ "$failed" -eq 0 ]]; then
  pass "DECISION: promote $TARGET ($SMOKE_REQUESTS/$SMOKE_REQUESTS requests OK)"
  exit 0
fi

notice "DECISION: roll back to $CURRENT ($failed/$SMOKE_REQUESTS requests failed on $TARGET)"
switch_to "$CURRENT"
failed=$(smoke)
[[ "$failed" -eq 0 ]] || abort "rollback to $CURRENT did not recover service ($failed failures)"
pass "rolled back: $CURRENT is serving again"
exit 10
