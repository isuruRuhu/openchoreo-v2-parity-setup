# Private-registry pull secrets (`registry-pull/`)

OpenChoreo has **no native `imagePullSecrets` support** (absent at upstream HEAD `296c0001`,
2026-07-20), so BYOI components with private-registry images need two pieces:

1. **The `image-pull-secret` / `image-pull-secret-cronjob` ClusterTraits** (`traits/`, installed and
   wired into allowedTraits by `setup.sh`) — patch `imagePullSecrets: [{name: <secretName>}]` into
   the rendered Deployment / CronJob pod spec. Attach one to each private-image component.
2. **The ClusterExternalSecret in this dir** (manual — NOT applied by `setup.sh`) — materializes the
   `ghcr-pull-secret` dockerconfigjson Secret in every current **and future** cell namespace, sourced
   from OpenBao through `ClusterSecretStore/default`.

## Setup (once per cluster)

```bash
# 1. Mint a registry credential. For GHCR: a CLASSIC PAT with read:packages ONLY
#    (fine-grained PATs cannot pull from GHCR).

# 2. Seed OpenBao (value on stdin — never in argv / shell history):
AUTH=$(printf '%s:%s' "<registry-user>" "<token>" | base64)
printf '{"auths":{"ghcr.io":{"auth":"%s"}}}' "$AUTH" \
  | kubectl exec -i -n openbao openbao-0 -- sh -c 'bao kv put secret/aiteam/ghcr-pull value=-'

# 3. Apply the ClusterExternalSecret (adjust remoteRef.key / registry host first if not GHCR):
kubectl apply -f registry-pull/ghcr-pull-clusterexternalsecret.yaml

# 4. Verify fan-out:
kubectl get clusterexternalsecret ghcr-pull-secret -o jsonpath='{.status.conditions}'
```

Then attach the trait on each private-image component:

```yaml
  traits:
    - instanceName: ghcr-pull
      kind: ClusterTrait
      name: image-pull-secret        # image-pull-secret-cronjob on scheduled/manual tasks
      parameters: {}                 # secretName defaults to ghcr-pull-secret
```

Rotation: write the new token to the same OpenBao key — ESO propagates within `refreshInterval`
(1h), no restarts. E2E-validated on the migration POC 2026-07-21 (private GHCR image → 1/1 Running;
evidence in the migration repo changelog `W7-ghcr-pull-secret.md`).
