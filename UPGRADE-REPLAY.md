# What a `helm upgrade` of OpenChoreo undoes — and how to recover

**Recovery is one command: re-run `./setup.sh --context <ctx>`.** The script converges
everything; already-correct pieces no-op.

This file explains *why* that's needed, based on evidence from a real OpenChoreo
1.1.0 → 1.1.1 upgrade performed on the reference (POC) cluster.

## The mechanics

Everything this repo installs falls into one of two classes:

- **New objects** (custom component types, traits, the WebSocket listener policy, the two
  Backstage ConfigMaps). Helm has no record of them, so chart upgrades leave them alone.
  These are durable.
- **Edits to objects the Helm charts own** (the cluster-agent ClusterRole, the built-in
  component types' allowed-traits/schema, the Backstage Deployment). Helm rewrites those
  objects to the chart's version during `helm upgrade`, silently discarding our edits.

## Observed on the 1.1.0 → 1.1.1 upgrade

| Piece | Survived? | Notes |
|---|---|---|
| Custom component types (api-proxy, manual-task, mcp-server) | ✅ yes | untouched |
| Custom traits (all five) | ✅ yes | untouched |
| Backstage ConfigMaps (template + extra catalog config) | ✅ yes | not Helm-managed |
| Backstage Deployment extra volumes/mounts | ✅ yes | Helm doesn't strip list entries it doesn't declare |
| Built-in component-type edits (allowed traits, validation, timezone enum) | ✅ yes, on that upgrade | the built-in types were not re-rendered by that chart upgrade — but do not rely on this; a bootstrap/install re-apply can reset them, so verify after upgrades |
| **Cluster-agent ClusterRole kgateway rule** | ❌ **reverted** | chart rewrote the role; every policy-emitting component silently broke until replayed |
| **Backstage startup arg (`--config app-config.extra.yaml`)** | ❌ **reverted** | chart re-rendered the Deployment args; the API Proxy card disappeared from the console until replayed |

The failure mode of the ClusterRole revert deserves emphasis: nothing errors visibly.
Components that emit gateway policies (API proxies, anything with jwt-auth/rate-limit/
cors/mediation) just stop routing — a curl returns 404 and no controller reports why.
**After any `helm upgrade`, re-run setup.sh, or at minimum check:**

```sh
kubectl --context <ctx> auth can-i create trafficpolicies.gateway.kgateway.dev \
  --as=system:serviceaccount:openchoreo-data-plane:cluster-agent-dataplane
```

(`setup.sh` runs this exact check in its verification step.)

## When these patches become unnecessary (upstream tracking)

Each patch is an interim carry until the equivalent lands in the OpenChoreo product.
Before applying this repo on a new OpenChoreo version, check whether it already ships:

| Interim patch in this repo | Upstream destination that retires it |
|---|---|
| Cluster-agent kgateway policy rule | data-plane chart, cluster-agent ClusterRole template |
| Allowed-traits additions on built-in component types | the built-in component-type definitions in the chart |
| Scheduled-task validation + timezone enum | scheduled-task definition in the chart |
| Backstage extra-config startup arg | control-plane chart exposing an `extraConfigFiles`-style values key |
| Hand-authored API Proxy create card | console shipping a native proxy-aware card (plus the skip-template-generation annotation support that hides duplicates) |

Once an item ships upstream, drop the corresponding step rather than fighting the chart.
