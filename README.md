# OpenChoreo V2-Parity Cluster Setup

Everything needed to bring a **stock OpenChoreo install** to the same state as the
Choreo-V2-parity POC cluster: the custom component types, gateway traits, permission
fixes, console card, and hardening that close the gaps between Choreo V2 and OpenChoreo.

## The full journey (start here)

Setting up a cluster from zero is five steps, in this order:

| Step | What | Where |
|---|---|---|
| 1 | Install OpenChoreo 1.1.1 on a Kubernetes cluster | [Step 1 below](#step-1--install-openchoreo) |
| 2 | Run `./setup.sh --context <ctx>` from this repo | [Step 2 below](#step-2--run-setupsh) |
| 3 | Do the manual per-cluster checklist (secrets, identity, console auth) | [Per-cluster checklist](#step-3--per-cluster-checklist-manual--cannot-be-stored-in-git) |
| 4 | Smoke-test with the bundled example | [Smoke test](#step-4--smoke-test) |
| 5 | Ongoing: after every `helm upgrade`, re-run `setup.sh` | [UPGRADE-REPLAY.md](UPGRADE-REPLAY.md) |

## Step 1 — Install OpenChoreo

This repo does **not** install OpenChoreo itself; it customizes an existing install.
Follow the official guide for installing on your own cluster:
<https://openchoreo.dev/docs/getting-started/try-it-out/on-your-environment/>
(or the k3d quick-start for a local test cluster:
<https://openchoreo.dev/docs/getting-started/quick-start-guide/>).

For this bundle to fully apply, the install must include (the official single-cluster
guide covers all of these):

- **Control plane** (`openchoreo-control-plane` chart) — includes the Backstage console.
- **Data plane** (`openchoreo-data-plane` chart) — includes the kgateway gateway and the
  cluster-agent whose ClusterRole this bundle patches.
- **Observability plane** (`openchoreo-observability-plane` chart) — needed by the
  `observability-alert-rule` trait wiring; the rest of the bundle works without it.
- **Thunder** (identity provider) — needed for console login and for the JWT-auth trait.

Pin the chart version to **1.1.1** (`--version 1.1.1` on each `helm install`) — that is
the version this bundle's patches were authored against (see Compatibility below).

## Step 2 — Run setup.sh

Clone this repo, then run one script against your cluster:

```sh
./setup.sh --context <your-kube-context>
```

The script is **idempotent** — safe to run repeatedly. Re-running it is also the recovery
procedure after any `helm upgrade` of the OpenChoreo charts (see
[UPGRADE-REPLAY.md](UPGRADE-REPLAY.md) for what an upgrade reverts and why).

Use `--dry-run` to preview everything without changing the cluster, and
`--skip-backstage` if the Backstage console is not installed.

The script ends with a verification block (component types + traits present, and an
`auth can-i` proof that the data-plane agent can create gateway policies). A non-zero
exit means something on the cluster needs attention — the output says what.

## Compatibility

Authored against **OpenChoreo 1.1.1** (single-cluster install: control plane, data plane
and observability plane on one cluster). The patches in `patches/` edit objects shipped
by the 1.1.1 Helm charts; on a newer OpenChoreo release, review
[UPGRADE-REPLAY.md](UPGRADE-REPLAY.md) first — some patches may already be part of the
product and become unnecessary.

Requirements on the machine running the script: `kubectl` (1.27+), `python3`, `bash`.

## What the script installs

### New component types (`component-types/`)

These are brand-new cluster-scoped objects. Helm never touches them, so they survive
product upgrades.

| Component type | What it gives you |
|---|---|
| `api-proxy` | Expose and manage an **existing external API** through the gateway — no code, no build. Supports JWT auth, rate limiting, CORS, header mediation, per-environment sandbox/production upstreams, and an OpenAPI spec attachment. This is the migration target for Choreo V2 "API Proxy" components. |
| `manual-task` | A run-on-demand task (Choreo V2 "Manual Task"). Modeled as a suspended cron job that never fires on its own; trigger a run with `kubectl create job --from=cronjob/<name> <run-name>`. |
| `mcp-server` | A service whose route **disables gateway request timeouts**, so long-lived streaming connections (Server-Sent Events, as used by MCP servers) stay open. |

### Reusable gateway traits (`traits/`)

Also new objects; survive upgrades. Each can be attached to a component from the console
or in the Component spec, with per-environment on/off control.

| Trait | What it does | Allowed on |
|---|---|---|
| `jwt-auth` | Require a valid JWT on the component's external endpoints | service, api-proxy |
| `rate-limit` | Per-route token-bucket rate limiting | service, api-proxy, web-application |
| `cors` | Cross-origin request policy (origins, methods, headers) | service, api-proxy, web-application |
| `mediation` | Add/remove request and response headers at the gateway | service, api-proxy, web-application |
| `autoscaler` | Horizontal pod autoscaling with per-environment min/max replicas and CPU/memory targets | service, web-application, worker |

Note: `api-proxy` also has its own built-in parameters for JWT/rate-limit/CORS/mediation.
Use **either** the built-in parameter **or** the matching trait on one component, never both
(both emit a policy for the same field on the same route).

### Patches to product-shipped objects (`patches/` + script logic)

These edit objects the OpenChoreo Helm charts own, which is why a `helm upgrade` can
silently undo them (re-run the script afterwards):

1. **Data-plane agent permissions** — adds three kgateway policy resource kinds
   (`backendconfigpolicies`, `trafficpolicies`, `gatewayextensions`) to the cluster-agent's
   ClusterRole. **Without this, every component type or trait that emits a gateway policy
   fails silently**: the policy never reaches the data plane, the sibling route is blocked
   with it, and the developer just sees a 404. This is the single most important patch here.
2. **Allowed-traits wiring** — registers the traits above on the built-in `service`,
   `web-application` and `worker` component types, and allows the alert-rule trait on
   `scheduled-task` (so cron-failure alerts can be attached).
3. **Scheduled-task input validation** — restricts concurrency/restart policy to their
   legal values and validates the cron expression at admission time, instead of letting a
   typo fail invisibly at render time.
4. **Scheduled-task timezone picker** — replaces the free-text timezone field with a
   598-entry IANA timezone dropdown (default UTC), matching the V2 create wizard.

### Backstage console pieces (`backstage/`)

A hand-authored **"API Proxy" create card** for the console: the scaffolder template
ConfigMap, a catalog config that registers it, and a Deployment patch that mounts both.
The ConfigMaps survive Helm upgrades; the injected startup argument does not (again:
re-run the script after upgrades).

Known caveat: on a stock console image you will see **two** API-proxy create cards — the
native auto-generated one and this one. The `api-proxy` component type already carries the
annotation that hides the native card; it takes effect once the console's
"skip template generation" feature ships in an upstream OpenChoreo release.

### Gateway hardening (`gateway/`)

An `HTTPListenerPolicy` that lets **WebSocket** connections upgrade through the data-plane
gateway. Without it the gateway answers WebSocket handshakes with 403, breaking every
migrated V2 WebSocket component. Part of the standard pre-flight hardening checklist.

## Step 3 — Per-cluster checklist (manual — cannot be stored in git)

The script cannot do these because they involve credentials or per-cluster choices.
Do them once per cluster:

1. **Registry push credential** — builds push images to a real registry, and the pipeline
   reads the credential from the OpenBao secret store. Put your registry credential in
   under the key the build pipeline expects, e.g.:
   ```sh
   bao kv put secret/registry-push-secret username=<user> password=<token> registry=<registry-host>
   ```
2. **Identity provider (Thunder) admin client** — user import (SCIM2) and client
   registration need an admin-capable client; none ships by default. Provision one, and
   extend the `openchoreo-user` schema with a `groups` attribute so role bindings work.
   See the official identity guide:
   <https://openchoreo.dev/docs/platform-engineer-guide/identity-configuration/>.
3. **Turn console authorization ON** — the default install ships the Backstage config with
   `dangerouslyDisableDefaultAuthPolicy: true`, which disables **all** permission
   enforcement in the console. Set it to `false` in the control-plane Helm values before
   giving real users access.
4. **(Optional) global rate quotas** — the `rate-limit` trait enforces per-route limits.
   If you need V2-style *global* quotas (one shared counter across replicas), additionally
   deploy an Envoy Rate Limit Service and wire it to the gateway.

## Step 4 — Smoke test

[`examples/api-proxy-smoke-test.yaml`](examples/api-proxy-smoke-test.yaml) creates one
API-proxy component that fronts `https://httpbin.org` — it exercises the custom component
type, the cluster-agent permission patch, and the full gateway policy chain in a single
apply, with no credentials needed:

```sh
kubectl --context <ctx> apply -f examples/api-proxy-smoke-test.yaml
# wait ~30s for reconciliation, then read the public URL from the release status:
kubectl --context <ctx> get releasebindings -n default \
  -l openchoreo.dev/component=httpbin-smoke \
  -o jsonpath='{.items[0].status.endpoints[0].externalURLs}'
curl <that-url>/get        # expect httpbin's JSON echo, HTTP 200
kubectl --context <ctx> delete -f examples/api-proxy-smoke-test.yaml   # clean up
```

If the route never materializes (404), the usual culprit is the cluster-agent permission
patch — re-run `setup.sh` and look at its verification output. Also worth checking in the
console: the create page should show the "API Proxy" card, and the built-in Service type's
create wizard should offer the jwt-auth / rate-limit / cors / mediation / autoscaler traits.

## Usage notes for migrated components

- **API proxies need a placeholder workload.** OpenChoreo currently requires every
  component — even a code-less proxy — to own one Workload object with an image set. The
  create card handles this for you; if you author proxy Components by hand, include a
  placeholder Workload with an `endpoints.default` entry (that key is also what makes the
  console show the invoke URL).
- **Manual tasks**: trigger with `kubectl create job --from=cronjob/<component-cronjob> <name>`;
  there is no console Run-Now button yet (tracked upstream).

## Not covered by this bundle

- **Platform AI add-ons** (FinOps agent, Portal Assistant) — these ship inside the 1.1.1
  charts and are enabled through Helm values plus their own API keys/secrets; enable them
  per the official docs if wanted. The OpenCost cost-metering module is a separate
  standalone Helm install.
- **Console UI features not yet released upstream** (proxy-card dedup, home-page cards,
  row-level delete) — these arrive with future OpenChoreo console releases; nothing to
  apply here.

## Community modules (`community-modules/` — documented separately, NOT applied by setup.sh)

`community-modules/gateway-wso2-api-platform/` contains the WSO2 API Platform gateway
module (operator Helm install, gateway custom resource, `api-management` trait, standalone
RBAC) used to connect OpenChoreo with WSO2 API Manager for consumer-facing API portal
features. It has its own [README](community-modules/gateway-wso2-api-platform/README.md)
and install steps. Treat it as opt-in: the validated setup was evaluation-grade
(development mode enabled, ephemeral in-memory database) and needs production hardening.
