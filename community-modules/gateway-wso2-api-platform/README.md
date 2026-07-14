# `gateway-wso2-api-platform` — WSO2 API Platform as an API-management layer behind kgateway

Reproducible install of the OpenChoreo community module
[`gateway-wso2-api-platform`](https://github.com/openchoreo/community-modules/tree/main/gateway-wso2-api-platform),
validated end-to-end on OpenChoreo **1.1.1** (kgateway 2.2.1). **Opt-in** — nothing in this
directory is applied by the bundle's `setup.sh`.

## What it is

Runs the **WSO2 API Platform gateway runtime behind kgateway**. kgateway stays the edge Gateway-API
controller; an `api-management` ClusterTrait reroutes a component's HTTPRoute through the WSO2 router
for policy enforcement. Data path:

```
client → kgateway (edge: TLS, hostname routing) → WSO2 router+policy → component Service → pod
```

The trait emits, per component: a kgateway `Backend` (Static → WSO2 runtime), a WSO2 `RestApi`
(derived context `/<env>-<ns>-<component>`, upstream = the component Service), and patches the
component's `HTTPRoute` (backendRef → the Backend; urlRewrite → the derived context).

For the full upstream documentation of the module itself, see
[upstream-README.md](upstream-README.md).

> **Check before installing — it may already be here.** Some enterprise clusters ship with
> the WSO2 api-platform gateway module pre-installed. Before running any of the install
> steps below, check the target cluster:
>
> ```bash
> kubectl --context <ctx> get apigateways -A      # existing APIGateway CRs?
> helm --kube-context <ctx> list -A | grep -i amp # existing 'amp' helm release?
> ```
>
> If either shows a result, the module is already installed — **skip this directory
> entirely** and use the existing install. Re-installing over it will collide (duplicate
> operator, CRDs, gateway CRs).

## How it relates to the traits in this bundle

This is a **second, heavier API-management path** that **coexists** with — does not replace — the
kgateway-native traits installed by `setup.sh`:

| | kgateway-native (this bundle's default) | this module |
|---|---|---|
| API Proxy | `api-proxy` component type (`workloadType: proxy`) | n/a (works on `service`-family component types via the trait) |
| Policies | `jwt-auth` / `rate-limit` / `cors` / `mediation` ClusterTraits → kgateway `TrafficPolicy`/`GatewayExtension` | one `api-management` trait → WSO2 `RestApi` policies (`cors`/`jwt-auth`/`basic-ratelimit`/`set-headers`) enforced in the WSO2 router |
| Data path | single hop (kgateway → Service) | **double hop** (kgateway → WSO2 router → Service) |
| Consumer portal (API docs, subscriptions/API keys, Try-It console) | architecturally absent | **bridge** — the operator ships `subscriptions`/`subscriptionplans`/`apikeys` CRDs; the full portal experience needs a connected external WSO2 API Manager 4.7.x+ (see "APIM-connect mode" below) |

Do **not** stack the kgateway-native policy traits AND `api-management` on the same component — pick
one enforcement path per component.

## Install order (behind-kgateway / default mode)

Use an explicit `--context <ctx>` on every command, matching the cluster you ran `setup.sh` against.

1. **Operator**:
   ```bash
   helm install api-platform-operator oci://ghcr.io/wso2/api-platform/helm-charts/gateway-operator \
     --version 0.8.0 --namespace openchoreo-data-plane --set gatewayApi.installStandardCRDs=false
   ```
   (`installStandardCRDs=false` because OpenChoreo already ships the Gateway-API CRDs. The operator
   installs the WSO2 CRDs: `restapis`, `apigateways`, `subscriptions`, `subscriptionplans`, `apikeys`, … .)
2. **Gateway config + APIGateway CR** — `kubectl apply -f gateway-configuration.yaml` then
   `kubectl apply -f apigateway.yaml`. The operator deploys the gateway chart
   (`oci://ghcr.io/wso2/api-platform/helm-charts/gateway` 1.1.0): pods
   `api-platform-default-gateway-controller-*` + `…-gateway-runtime-*`.
3. **RBAC** — `kubectl apply -f rbac.yaml`. This is a standalone ClusterRole + ClusterRoleBinding for
   the data-plane cluster-agent, deliberately **not** a patch of the agent's chart-owned role — so it
   **survives data-plane helm upgrades** (see the note in `rbac.yaml`).
4. **Trait** — `kubectl apply -f api-management-trait.yaml`.
5. **Enable on a ComponentType** — add `api-management` to its `allowedTraits` (additive; inert for
   components that don't reference it):
   ```bash
   kubectl patch clustercomponenttype service --type='json' \
     -p='[{"op":"add","path":"/spec/allowedTraits/-","value":{"name":"api-management","kind":"ClusterTrait"}}]'
   ```

To try it, `sample-component.yaml` shows the trait attached to a service component, and
`test-component.yaml` is the exact component used in the original validation (all policies on).

## What was validated

On OpenChoreo 1.1.1, with the trait attached to a test service component:

- ReleaseBinding `Ready=True`; trait emitted the Backend (Static, ready) + RestApi
  (Accepted+Programmed, "Successfully deployed to gateway") + patched HTTPRoute.
- A request through the gateway returned **200** from the component, with the WSO2 runtime's
  access log proving the request took the WSO2 hop and its policy engine parsed the config.
- **rate-limit** (5/min): burst → `200,200,200,429,429,…`
- **add-headers**: response carried the configured `x-powered-by` header
- **jwtAuth**: no token → **401**; bogus bearer → **401**

## APIM-connect mode (external WSO2 API Manager)

Standalone mode enforces policies but has no consumer portal. Connecting a WSO2 API Manager
(4.7.0+) gives Publisher/DevPortal, with locally-created `RestApi` CRs auto-importing into the
APIM Publisher (`gatewayType: APIPlatform`). Validated flow:

- **Install APIM in-cluster (evaluation-grade)**:
  `helm install wso2am wso2/wso2am-all-in-one --version 4.7.0-1 -n wso2-apim -f apim-values.yaml`
  (`apim-values.yaml` in this directory — embedded H2 database, built-in keystores, no ingress;
  **state is ephemeral**: an APIM pod restart resets gateways/tokens/APIs → re-run registration.
  Gotcha: the chart's default truststore password is `""`, which crashes `user.core` at startup —
  the values file pins it to `wso2carbon`.)
- **Register the gateway (all REST, no portal needed)**: create a DCR client via
  `POST /client-registration/v0.17/register` (basic admin:admin), get an admin token via password
  grant with scope `apim:admin`, then `POST /api/am/admin/v4/gateways` with
  `{name, displayName, vhost}` — the response carries a one-time `registrationToken`.
- **Wire the gateway controller**: fill in `gateway-configuration.yaml` —
  `controlplane.apim_oauth2_client_id/secret` (**redacted placeholders in this repo — use the
  values your DCR call returns**), `gateway_name`, `controlPlane.host`
  (e.g. `wso2am-am-service.wso2-apim:9443`), and the registration token. Apply it, then annotate
  `apigateway/api-platform-default` with `reconcile-trigger=<anything-new>` to roll the controller.
- **Verify**: controller logs show `Control plane connection established`; the gateway shows
  `isActive=True` in `/api/am/admin/v4/gateways`; a local `RestApi` CR appears in APIM Publisher.
  Deleting the CR undeploys it from the gateway, but the Publisher record persists (governance
  record) — remove via the Publisher REST API if needed.
- Portal access without ingress: `kubectl port-forward -n wso2-apim svc/wso2am-am-service 9444:9443`
  → `https://localhost:9444/admin` | `/publisher` | `/devportal` (admin/admin).

## Production hardening (NOT production-ready as shipped)

- `gateway-configuration.yaml` ships with **`developmentMode: true`** (relaxes encryption-key
  enforcement) and placeholder control-plane credentials — replace both before any real use.
- The in-cluster APIM recipe above is evaluation-grade: embedded **H2** (ephemeral), default
  keystores, default admin password. Production needs an external RDBMS, real keystores/encryption
  keys, HA, and deliberate exposure.
- Behind-kgateway adds a **second full Envoy data path** (extra controller + runtime pod pair,
  requests 500m/1Gi, limits 2/4Gi) and a second network hop — a real topology/latency/cost change.
