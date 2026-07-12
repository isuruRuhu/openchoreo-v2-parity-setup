# `gateway-wso2-api-platform` — WSO2 API Platform as an API-management layer behind kgateway

Reproducible install of the OpenChoreo community module
[`gateway-wso2-api-platform`](https://github.com/openchoreo/community-modules/tree/main/gateway-wso2-api-platform),
validated end-to-end on `choreo-migration-poc-cluster` (OC 1.1.1, kgateway 2.2.1) on **2026-06-05**.

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

## How it relates to what we already shipped

This is a **second, heavier APIm path** that **coexists** with — does not replace — our existing work:

| | kgateway-native (already shipped) | this module |
|---|---|---|
| API Proxy | `api-proxy` CT (`workloadType: proxy`) | n/a (works on `service`-family CTs via the trait) |
| Policies | `jwt-auth` / `rate-limit` / `cors` / `mediation` ClusterTraits → kgateway `TrafficPolicy`/`GatewayExtension` | one `api-management` trait → WSO2 `RestApi` policies (`cors`/`jwt-auth`/`basic-ratelimit`/`set-headers`) enforced in the WSO2 router |
| Data path | single hop (kgateway → Service) | **double hop** (kgateway → WSO2 router → Service) |
| Consumer portal (F105/106/107) | architecturally absent | **bridge** — the operator ships `subscriptions`/`subscriptionplans`/`apikeys` CRDs; full portal needs the external WSO2 API Manager 4.7.x+ connection (out of scope here) |

Do **not** stack the kgateway-native policy traits AND `api-management` on the same component — pick
one enforcement path per component.

## Install order (behind-kgateway / default mode)

All commands target the POC: `--kube-context choreo-migration-poc-cluster` / `--context=choreo-migration-poc-cluster`.

1. **Operator** (digest `sha256:6668ef12…578efb`):
   ```bash
   helm install api-platform-operator oci://ghcr.io/wso2/api-platform/helm-charts/gateway-operator \
     --version 0.8.0 --namespace openchoreo-data-plane --set gatewayApi.installStandardCRDs=false
   ```
   (`installStandardCRDs=false` because OC already ships the Gateway-API CRDs. The operator installs
   the WSO2 CRDs: `restapis`, `apigateways`, `subscriptions`, `subscriptionplans`, `apikeys`, … .)
2. **Gateway config + APIGateway CR** — `kubectl apply -f gateway-configuration.yaml` then
   `kubectl apply -f apigateway.yaml`. The operator deploys the gateway chart
   (`oci://ghcr.io/wso2/api-platform/helm-charts/gateway` 1.1.0, digest `sha256:5771dcec…66c6b1`):
   pods `api-platform-default-gateway-controller-*` + `…-gateway-runtime-*`.
3. **RBAC** — `kubectl apply -f rbac.yaml` (standalone ClusterRole+Binding → SA
   `cluster-agent-dataplane`/`openchoreo-data-plane`; **survives data-plane helm upgrades** — see the
   note in `rbac.yaml`).
4. **Trait** — `kubectl apply -f api-management-trait.yaml`.
5. **Enable on a ComponentType** — add `api-management` to its `allowedTraits` (additive, inert for
   components that don't reference it):
   ```bash
   kubectl patch clustercomponenttype service --type='json' \
     -p='[{"op":"add","path":"/spec/allowedTraits/-","value":{"name":"api-management","kind":"ClusterTrait"}}]'
   ```
   > On the POC this step was applied for validation then **reverted** — the module is installed but
   > not yet enabled on any shipped CT. Re-run the patch to enable it for real.

## Validation evidence (2026-06-05, POC)

- ReleaseBinding `Ready=True`; trait emitted Backend (Static, ready) + RestApi (Accepted+Programmed,
  "Successfully deployed to gateway") + patched HTTPRoute (backendRef → `…-api-gw-backend`,
  urlRewrite → `/development-default-wso2apim-test-greeter`).
- `GET …/wso2apim-test-greeter-http/greeter/greet?name=poc` → **200 `Hello, poc!`**; WSO2 runtime
  `[rtr]` access log shows the request at `response_code:200`, upstream
  `cluster_http_wso2apim-test-greeter_…:9090`, and `[pol]` parsed the API policy config → proves the
  WSO2 hop.
- **rate-limit** (5/min): burst → `200,200,200,429,429,…` ✓
- **add-headers**: response carried `x-powered-by: OpenChoreo-WSO2` ✓
- **jwtAuth**: no token → **401**; bogus bearer → **401** ✓
- CEL template fns (`${workload.toServicePorts()[0].port}`, `${metadata.environmentName}`, …) and
  policy `version: "v1"` **resolved/were accepted on OC 1.1.1** (the README's "latest dev build"
  target did not bite).

Full changelog: `v2-parity/changelogs/WSO2APIM-1-gateway-module-install.md`.

## APIM-connect mode (DONE 2026-06-12 — see `changelogs/WSO2APIM-2-apim-connect.md`)

WSO2 API Manager **4.7.0** now runs in-cluster and the gateway is **connected** (registered, WebSocket
established, bottom-up API sync working):

- **Install:** `helm install wso2am wso2/wso2am-all-in-one --version 4.7.0-1 -n wso2-apim -f apim-values.yaml`
  (`apim-values.yaml` in this directory — embedded H2, built-in keystores, no ingress; **POC-only,
  state is ephemeral**: an APIM pod restart resets gateways/tokens/APIs → re-run registration).
  Gotcha: the chart's default truststore password is `""` which NPEs `user.core` at startup — the
  values file pins it to `wso2carbon`.
- **Registration (all REST, no portal needed):** DCR client via
  `POST /client-registration/v0.17/register` (basic admin:admin), admin token via password grant
  scope `apim:admin`, then `POST /api/am/admin/v4/gateways` with `{name, displayName, vhost}` →
  response carries the one-time `registrationToken`.
- **Wiring:** `gateway-configuration.yaml` here carries the live values —
  `controlplane.apim_oauth2_client_id/secret` (DCR client), `gateway_name: oc-platform-gateway`,
  `controlPlane.host: wso2am-am-service.wso2-apim:9443`, `controlPlane.token.value`. Apply + annotate
  `apigateway/api-platform-default` with `reconcile-trigger=<anything-new>` to roll the controller.
- **Validated:** handshake success sequence in controller logs (`Control plane connection established`),
  `oc-platform-gateway isActive=True` in `/api/am/admin/v4/gateways`, and a local `RestApi` CR
  auto-imported into APIM Publisher (`gatewayType: APIPlatform`). Deleting the CR undeploys from the
  gateway but the APIM Publisher record persists (governance record) — delete via Publisher REST if needed.
- Portal access: `kubectl port-forward -n wso2-apim svc/wso2am-am-service 9444:9443` →
  `https://localhost:9444/admin` | `/publisher` | `/devportal` (admin/admin).

## Out of scope here (follow-ups)

- **Bake into the OpenChoreo install / Helm values** (the durable "ship by default" step).
- **kgateway changes for APIm / api-proxy** integration (the secondary task).
- **Consumer-side gap enumeration on the connected APIM devportal** — the actual closure verification for
  F105 api-docs / F106 subscription+API-key / F107 Try-It (what maps cleanly from V2's portal model, what doesn't).
- **Edge mode** (WSO2 replacing kgateway).
- **Production APIM topology** — external RDBMS instead of H2, real keystores/encryption key, HA, exposure.

## Prod-hardening notes (not for prod as-shipped)

- The shipped `gateway-configuration.yaml` has **`developmentMode: true`** (relaxes encryption-key
  enforcement) and embeds a **placeholder APIM control-plane token + OAuth creds** — scrub both before
  any non-POC use. Inert in standalone mode (no APIM connected) but must not ship to prod.
- Behind-kgateway adds a **second full Envoy data path** (extra controller + runtime pod pair,
  req 500m/1Gi, lim 2/4Gi) and a second network hop — a real topology/latency/cost change.
