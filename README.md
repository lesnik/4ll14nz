# Blue/green deployments as a Crossplane API

A small Crossplane (v1) exercise on a local kind cluster. One claim describes an
application; changing a single field on that claim switches traffic between two
release slots, and an unattended script decides whether to keep the switch or roll
it back.

```
./run.sh     # kind cluster -> Crossplane -> provider/functions -> API -> demo (switch + rollback)
./down.sh    # delete the cluster
```

Requirements: `docker` (running), `kind`, `kubectl`, `helm`. Developed on macOS with
Colima as the Docker runtime; nothing here is Colima specific. A cold run takes about
2 minutes, most of it image pulls. The script never touches your own kubeconfig: it
writes `./.kubeconfig` and uses only that.

The application is [podinfo](https://github.com/stefanprodan/podinfo). It answers
`GET /` with a configurable message and `GET /healthz` with its own health state,
which is enough to tell the slots apart and to build a broken release from.

`run.sh` asserts both outcomes (exit code 0 = promoted, 10 = rolled back) and fails
if either decision is not the expected one, so the run is self-checking.

## The API

`App` (claim) / `XApp` (composite), group `demo.milan.dev`, defined in
[`api/xrd.yaml`](api/xrd.yaml).

```yaml
apiVersion: demo.milan.dev/v1alpha1
kind: App
metadata:
  name: podinfo
spec:
  activeColor: blue            # <- the switch. blue | green
  replicas: 1
  port: 9898
  blue:                        # release slot
    version: "1.0.0"
    image: stefanprodan/podinfo:6.15.0
    env:
      PODINFO_UI_MESSAGE: v1 served by blue
  green:                       # release slot
    version: "2.0.0"
    image: stefanprodan/podinfo:6.15.0
    env:
      PODINFO_UI_MESSAGE: v2 served by green
status:
  servingColor: blue           # observed from the real Service selector
  blue:  { version: "1.0.0", ready: true }   # observed from the real Deployment
  green: { version: "2.0.0", ready: true }
```

The Composition ([`api/composition.yaml`](api/composition.yaml)) is a two-step
function pipeline: `function-go-templating` renders the resources and the status,
`function-auto-ready` derives the composite's Ready condition from them. It creates,
through `provider-kubernetes` `Object`s:

- `Deployment podinfo-blue` and `Deployment podinfo-green`, one per slot, labelled
  `app=podinfo, color=<slot>, version=<slot.version>`
- `Service podinfo` with selector `app=podinfo, color=<spec.activeColor>`

Switching is a label-selector change on one Service. Both releases are already
running and warmed up before any traffic moves, so the switch is atomic and takes
effect as soon as it is applied. Moving back is the same operation.

### Why it looks like this

The claim names both slots rather than a "current" and a "next" release. Blue/green
has two long-lived environments and operators think in terms of which slot is free, so
the spec lists what is in blue, what is in green, and which one is live. A rollback is
setting `activeColor` back to the previous value.

Each slot carries a `version` next to its image and environment. Configuration is
passed as environment variables rather than command-line arguments so the API does not
depend on how an image defines its entrypoint (see "What didn't work" below). The version is stamped on
the pod template and read back from the real Deployment into `status.<color>.version`,
so the automation can compare what is rolled out with what the claim asks for before
it sends traffic there (see "What didn't work" below).

Everything under `status` is read back from the cluster. `status.servingColor` comes
from the Service that exists (`Object.status.atProvider.manifest.spec.selector.color`).
It lags `spec.activeColor` for a moment after a patch, and that lag is how the script
knows when the switch has actually been applied. `status.<color>.ready` is derived
from the Deployment's real status via a CEL readiness query on the `Object`: the
controller has observed the latest generation, all replicas are updated and
available. The built-in readiness policies did not fit: `DeriveFromObject` wants a `Ready` condition
that Deployments do not have, and `AllTrue` is satisfied during a rollout because
`Available` stays true while the old pod is still serving.

The promote or rollback decision lives outside the Composition, in
[`scripts/promote.sh`](scripts/promote.sh). A Composition is a pure, re-entrant
function from desired plus observed state to desired state; it has no notion of time
or sequence, and promote-then-probe-then-maybe-revert is a workflow. What the
Composition does is make the switch a one-field change and publish observed status
the script can base its decision on. The same script could be a CI job, an Argo
Workflow step or a small operator without changing the API.

`provider-kubernetes` needs no cloud account, and its `Object` exposes the full
observed manifest, which the status logic relies on. `function-go-templating` was
picked because the two Deployments are a loop over `["blue", "green"]` and the status
needs booleans computed from observed state. Patch-and-transform would have doubled
every patch and cannot express that.

The readiness probe is TCP on purpose. The broken v3 build starts, listens and
serves pages, but reports itself unhealthy (`PODINFO_UNHEALTHY=true` makes
`/healthz` answer 503, the way an app would when it cannot reach its database). With
an HTTP readiness probe Kubernetes would catch this one, but many real failures
(bad config, one broken route, dead downstream) pass probes. The demo shows the layer
that catches those: an end-to-end check after the switch, with the ability to undo.

## The automation

`scripts/promote.sh <color>`, exit code 0 promoted, 10 rolled back, 20 aborted.

1. **Gate 1, before touching traffic.** Wait until
   `status.<target>.version == spec.<target>.version` and `status.<target>.ready`.
   If that does not happen within the timeout, abort. Nothing was switched.
2. **Switch.** Patch `spec.activeColor`. Wait until `status.servingColor` reports
   the new colour, i.e. the Service in the cluster really points there.
3. **Gate 2, smoke test.** Ten `GET /healthz` requests through the Service from a
   probe pod inside the cluster, so they take the same path real traffic takes. Any
   non-200 counts as a failure.
4. **Decide.** Zero failures: promoted. Otherwise patch `activeColor` back to the
   previous colour, wait for `servingColor` to follow, smoke test again to prove the
   rollback actually restored service.

Versions pinned: Crossplane 1.20.13, provider-kubernetes v0.18.0,
function-go-templating v0.13.0, function-auto-ready v0.7.0, kind node v1.37.0,
podinfo 6.15.0.
