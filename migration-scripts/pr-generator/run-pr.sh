#!/usr/bin/env bash
# Open a PR authored by the Choreo GitHub App, from a throwaway Job in the CP cluster.
#
# The app private key is read from the env the dp-cicd deployment already mounts, so the
# key never leaves the cluster and is never written to a workstation. The Job runs on the
# dp-cicd image (Node 20: crypto + fetch, no deps) and is deleted when the run finishes.
#
#   ./run-pr.sh payload.json
#   KUBE_CONTEXT=choreo-stage-cp NAMESPACE=stage-choreo-system ./run-pr.sh payload.json
set -euo pipefail

PAYLOAD="${1:?usage: $0 <payload.json>}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KUBE_CONTEXT="${KUBE_CONTEXT:-choreo-dev-cp}"
NAMESPACE="${NAMESPACE:-dev-choreo-system}"
DEPLOYMENT="${DEPLOYMENT:-dp-cicd}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-sa-choreo-default}"
APP_ID_KEY="${APP_ID_KEY:-GITHUB_APP_ID}"
APP_KEY_KEY="${APP_KEY_KEY:-CHOREO-GITHUB-APP-PRIVATE-KEY}"

k() { kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" "$@"; }

# Discover image + the configmap/secret the live deployment reads, so this keeps working
# across redeploys instead of pinning a stale image tag.
echo "discovering config from deployment/$DEPLOYMENT in $KUBE_CONTEXT/$NAMESPACE ..."
DEPLOY_JSON=$(k get deploy "$DEPLOYMENT" -o json --request-timeout=30s)
IMAGE=$(printf '%s' "$DEPLOY_JSON" | jq -r '.spec.template.spec.containers[0].image')
# GITHUB_APP_ID arrives via a bulk envFrom.configMapRef, not an individual key ref,
# so probe each referenced configMap for the key.
APP_ID_CM=$(printf '%s' "$DEPLOY_JSON" | jq -r --arg k "$APP_ID_KEY" \
  '[.spec.template.spec.containers[0].env[]?|select(.name==$k)|.valueFrom.configMapKeyRef.name][0] // empty')
if [[ -z "$APP_ID_CM" ]]; then
  for cm in $(printf '%s' "$DEPLOY_JSON" | jq -r \
      '.spec.template.spec.containers[0].envFrom[]?|.configMapRef.name//empty'); do
    if k get configmap "$cm" -o json --request-timeout=30s 2>/dev/null \
         | jq -e --arg k "$APP_ID_KEY" '.data|has($k)' >/dev/null; then
      APP_ID_CM="$cm"; break
    fi
  done
fi
APP_KEY_SECRET=$(printf '%s' "$DEPLOY_JSON" | jq -r --arg k "$APP_KEY_KEY" \
  '[.spec.template.spec.containers[0].env[]?|select(.valueFrom.secretKeyRef.key==$k)|.valueFrom.secretKeyRef.name][0] // empty')
[[ -z "$APP_ID_CM"     ]] && { echo "could not find configMap holding $APP_ID_KEY"; exit 1; }
[[ -z "$APP_KEY_SECRET" ]] && { echo "could not find secret holding $APP_KEY_KEY"; exit 1; }
echo "  image      : $IMAGE"
echo "  app id from: configmap/$APP_ID_CM"
echo "  app key    : secret/$APP_KEY_SECRET (never read locally)"

STAMP=$(date +%s); JOB="gh-app-pr-$STAMP"; CM="gh-app-pr-src-$STAMP"
cleanup() {
  echo "--- cleanup ---"
  k delete job "$JOB" --ignore-not-found --request-timeout=30s >/dev/null 2>&1 || true
  k delete configmap "$CM" --ignore-not-found --request-timeout=30s >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Script + payload travel as a ConfigMap volume: `kubectl exec` puts argv in the request
# URL and ingress proxies 414 on anything sizeable.
k create configmap "$CM" \
  --from-file=open-pr.js="$DIR/open-pr.js" \
  --from-file=payload.json="$PAYLOAD" --request-timeout=60s

k apply --request-timeout=30s -f - <<YAML
apiVersion: batch/v1
kind: Job
metadata: { name: $JOB, labels: { purpose: gh-app-migration } }
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 300
  template:
    metadata: { labels: { purpose: gh-app-migration } }
    spec:
      restartPolicy: Never
      serviceAccountName: $SERVICE_ACCOUNT
      securityContext: { seccompProfile: { type: RuntimeDefault } }
      containers:
        - name: open-pr
          image: $IMAGE
          command: ["node", "/script/open-pr.js"]
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: ["all"] }
            readOnlyRootFilesystem: true
            runAsUser: 10001
            runAsGroup: 10001
            seccompProfile: { type: RuntimeDefault }
          env:
            - name: GITHUB_APP_ID
              valueFrom: { configMapKeyRef: { name: $APP_ID_CM, key: $APP_ID_KEY } }
            - name: GITHUB_APP_PRIVATE_KEY
              valueFrom: { secretKeyRef: { name: $APP_KEY_SECRET, key: $APP_KEY_KEY } }
          volumeMounts:
            - { name: script, mountPath: /script, readOnly: true }
            - { name: tmp, mountPath: /tmp }
      volumes:
        - name: script
          configMap: { name: $CM }
        - name: tmp
          emptyDir: {}
YAML

echo "waiting for job/$JOB ..."
k wait --for=condition=complete "job/$JOB" --timeout=240s --request-timeout=250s 2>/dev/null \
  || k wait --for=condition=failed "job/$JOB" --timeout=10s --request-timeout=20s 2>/dev/null || true
echo "=================== JOB OUTPUT ==================="
k logs "job/$JOB" --request-timeout=60s || echo "(no logs — pod may not have started)"
echo "================================================="
