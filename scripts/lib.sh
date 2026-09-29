#!/usr/bin/env bash
#
# (C) AllSet DevOps, s.r.o.
#
# Shared helpers.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$ROOT/.kubeconfig}"
CLUSTER="xp-bluegreen"
APP="${APP:-podinfo}"
NS="${NS:-default}"

# Plain, kept boring on purpose.
step()   { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
pass()   { printf '[%s] OK   %s\n' "$(date +%H:%M:%S)" "$*"; }
notice() { printf '[%s] WARN %s\n' "$(date +%H:%M:%S)" "$*"; }
abort()  { printf '[%s] FAIL %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# wait_for "<what>" <timeout-seconds> <command...>  - polls until the command
# succeeds; returns 1 (after a warning) on timeout so callers decide what to do.
wait_for() {
  local what=$1 timeout=$2; shift 2
  local start=$SECONDS
  until "$@" >/dev/null 2>&1; do
    if (( SECONDS - start > timeout )); then
      notice "timed out after ${timeout}s waiting for: $what"
      return 1
    fi
    sleep 2
  done
}

app_field() { kubectl -n "$NS" get app "$APP" -o jsonpath="{$1}" 2>/dev/null; }

# http_get [path] -> "<status-code> <body>", via the in-cluster probe pod.
# The status code is the last line of curl's output; everything before it is the body.
http_get() {
  local path=${1:-/} out code body
  out=$(kubectl -n "$NS" exec probe -- \
    curl -s --max-time 2 -w '\n%{http_code}' "http://$APP.$NS.svc$path" 2>/dev/null) || true
  code=${out##*$'\n'}
  body=${out%$'\n'*}
  printf '%s %s\n' "${code:-000}" "$(printf '%s' "$body" | tr '\n' ' ')"
}

# serving -> "<status-code> <ui message>": who answers GET / right now
serving() {
  local res; res=$(http_get /)
  printf '%s %s\n' "${res%% *}" "$(printf '%s' "$res" | grep -o '"message": *"[^"]*"' | cut -d'"' -f4)"
}

# wait_for_http <timeout-seconds> - until the app answers HTTP 200 through the Service
wait_for_http() {
  local timeout=$1 start=$SECONDS
  until [[ "$(http_get /healthz)" == 200* ]]; do
    (( SECONDS - start > timeout )) && { notice "app did not answer HTTP 200 within ${timeout}s"; return 1; }
    sleep 2
  done
}
