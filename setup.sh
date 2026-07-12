#!/usr/bin/env bash
# Brings a stock OpenChoreo cluster to V2-parity state (mirrors the POC cluster).
#
# Usage:
#   ./setup.sh --context <kube-context> [--skip-backstage] [--dry-run]
#
#   --context        REQUIRED. Never operates on the current kubectl context implicitly.
#   --skip-backstage Skip the console pieces (use when the Backstage console is not installed).
#   --dry-run        Server-side dry-run of every apply/patch; mutates nothing.
#
# The script is idempotent: every step either no-ops or converges when re-run.
# Re-running it IS the recovery procedure after `helm upgrade` of the OpenChoreo
# charts (see UPGRADE-REPLAY.md for what reverts and why).
#
# Requirements: kubectl (>=1.27), python3, bash.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTEXT=""
SKIP_BACKSTAGE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)        CONTEXT="${2:?--context needs a value}"; shift 2 ;;
    --skip-backstage) SKIP_BACKSTAGE=true; shift ;;
    --dry-run)        DRY_RUN=true; shift ;;
    -h|--help)        grep '^#' "$0" | head -16; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$CONTEXT" ]]; then
  echo "ERROR: --context is required (this script never uses the current context implicitly)." >&2
  exit 2
fi

KC=(kubectl --context="$CONTEXT")
# Always non-empty so "${APPLY_FLAGS[@]}" is safe under `set -u` on bash 3.2 (macOS default).
APPLY_FLAGS=(--request-timeout=90s)
if $DRY_RUN; then APPLY_FLAGS+=(--dry-run=server); fi

log()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

# ---------------------------------------------------------------- preflight --

log "Preflight: cluster + OpenChoreo sanity on context '$CONTEXT'"

"${KC[@]}" version --request-timeout=10s >/dev/null \
  || { echo "ERROR: cluster unreachable via context '$CONTEXT'" >&2; exit 1; }

for crd in clustercomponenttypes.openchoreo.dev clustertraits.openchoreo.dev; do
  "${KC[@]}" get crd "$crd" >/dev/null \
    || { echo "ERROR: CRD $crd not found — is OpenChoreo installed?" >&2; exit 1; }
done

for ct in service web-application worker scheduled-task; do
  "${KC[@]}" get clustercomponenttype "$ct" >/dev/null \
    || { echo "ERROR: built-in ComponentType '$ct' missing — unexpected OpenChoreo install state" >&2; exit 1; }
done

"${KC[@]}" get clusterrole cluster-agent-dataplane-openchoreo-data-plane >/dev/null \
  || { echo "ERROR: data-plane cluster-agent ClusterRole not found (single-cluster install expected)" >&2; exit 1; }

if ! "${KC[@]}" get crd httplistenerpolicies.gateway.kgateway.dev >/dev/null 2>&1; then
  note "WARN: kgateway HTTPListenerPolicy CRD missing — the WebSocket fix will be skipped."
  SKIP_GATEWAY=true
else
  SKIP_GATEWAY=false
fi

if ! $SKIP_BACKSTAGE && ! "${KC[@]}" -n openchoreo-control-plane get deploy backstage >/dev/null 2>&1; then
  note "WARN: Backstage deployment not found in openchoreo-control-plane — skipping console pieces."
  SKIP_BACKSTAGE=true
fi

# ------------------------------------------------- new cluster-scoped objects --

log "Applying custom ComponentTypes (api-proxy, manual-task, mcp-server)"
"${KC[@]}" apply "${APPLY_FLAGS[@]}" -f "$SCRIPT_DIR/component-types/"

log "Applying ClusterTraits (jwt-auth, rate-limit, cors, mediation, autoscaler)"
"${KC[@]}" apply "${APPLY_FLAGS[@]}" -f "$SCRIPT_DIR/traits/"

if ! $SKIP_GATEWAY; then
  log "Applying WebSocket upgrade HTTPListenerPolicy (data-plane gateway)"
  "${KC[@]}" apply "${APPLY_FLAGS[@]}" -f "$SCRIPT_DIR/gateway/"
fi

# --------------------------------------- patches to chart-shipped objects --
# These edit objects the OpenChoreo Helm charts own. They are re-applied
# (converged) on every run; `helm upgrade` may revert them — re-run this script.

log "Ensuring cluster-agent ClusterRole covers kgateway policy CRDs"
if "${KC[@]}" get clusterrole cluster-agent-dataplane-openchoreo-data-plane -o json \
     | python3 -c 'import json,sys; rules=json.load(sys.stdin).get("rules") or []; sys.exit(0 if any("backendconfigpolicies" in (r.get("resources") or []) for r in rules) else 1)'; then
  note "rule already present — skipping"
else
  "${KC[@]}" patch clusterrole cluster-agent-dataplane-openchoreo-data-plane \
    --type=json --patch-file="$SCRIPT_DIR/patches/cluster-agent-kgateway-rule.json" "${APPLY_FLAGS[@]}"
  note "added kgateway policy rule (backendconfigpolicies/trafficpolicies/gatewayextensions)"
fi

# ensure_allowed_traits <componenttype> <trait> [<trait> ...]
# Unions the traits into .spec.allowedTraits (replace-list merge patch, computed additively).
ensure_allowed_traits() {
  local ct="$1"; shift
  local patch
  patch="$("${KC[@]}" get clustercomponenttype "$ct" -o json | python3 -c '
import json, sys
desired = sys.argv[1:]
obj = json.load(sys.stdin)
cur = obj["spec"].get("allowedTraits") or []
names = {t.get("name") for t in cur}
add = [{"kind": "ClusterTrait", "name": n} for n in desired if n not in names]
print(json.dumps({"spec": {"allowedTraits": cur + add}}) if add else "")
' "$@")"
  if [[ -n "$patch" ]]; then
    "${KC[@]}" patch clustercomponenttype "$ct" --type=merge -p "$patch" "${APPLY_FLAGS[@]}"
    note "$ct: allowedTraits updated (+$*)"
  else
    note "$ct: allowedTraits already complete"
  fi
}

log "Ensuring built-in ComponentTypes allow the parity traits"
ensure_allowed_traits service         jwt-auth rate-limit cors mediation autoscaler
ensure_allowed_traits web-application rate-limit cors mediation autoscaler
ensure_allowed_traits worker          autoscaler
ensure_allowed_traits scheduled-task  observability-alert-rule

log "Hardening scheduled-task input validation (enums + cron pattern)"
"${KC[@]}" patch clustercomponenttype scheduled-task --type=merge \
  --patch-file="$SCRIPT_DIR/patches/scheduled-task-l5-constraints.json" "${APPLY_FLAGS[@]}"

log "Installing scheduled-task IANA timezone picker (598-zone enum, default UTC)"
"${KC[@]}" patch clustercomponenttype scheduled-task --type=merge \
  --patch-file="$SCRIPT_DIR/patches/scheduled-task-timezone-enum.json" "${APPLY_FLAGS[@]}"

# --------------------------------------------------------- Backstage console --

if ! $SKIP_BACKSTAGE; then
  log "Applying Backstage scaffolder ConfigMaps (Create API Proxy card)"
  "${KC[@]}" apply "${APPLY_FLAGS[@]}" -f "$SCRIPT_DIR/backstage/"

  log "Wiring the template + extra config into the Backstage Deployment"
  # Volumes / volumeMounts merge by name (strategic merge patch), so this is idempotent.
  "${KC[@]}" -n openchoreo-control-plane patch deploy backstage --type=strategic "${APPLY_FLAGS[@]}" -p '{
    "spec": {"template": {"spec": {
      "volumes": [
        {"name": "extra-catalog-config", "configMap": {"name": "backstage-extra-catalog-config"}},
        {"name": "template-create-api-proxy", "configMap": {"name": "backstage-template-create-api-proxy"}}
      ],
      "containers": [{
        "name": "backstage",
        "volumeMounts": [
          {"name": "extra-catalog-config", "mountPath": "/app/app-config.extra.yaml", "subPath": "app-config.extra.yaml", "readOnly": true},
          {"name": "template-create-api-proxy", "mountPath": "/app/templates/create-api-proxy/template.yaml", "subPath": "template.yaml", "readOnly": true}
        ]
      }]
    }}}
  }'

  # Container args are replaced wholesale by strategic merge, so append additively instead.
  args_patch="$("${KC[@]}" -n openchoreo-control-plane get deploy backstage -o json | python3 -c '
import json, sys
obj = json.load(sys.stdin)
c = obj["spec"]["template"]["spec"]["containers"][0]
args = c.get("args") or []
if "app-config.extra.yaml" in args:
    print("")
else:
    print(json.dumps({"spec": {"template": {"spec": {"containers": [
        {"name": c["name"], "args": args + ["--config", "app-config.extra.yaml"]}]}}}}))
')"
  if [[ -n "$args_patch" ]]; then
    "${KC[@]}" -n openchoreo-control-plane patch deploy backstage --type=strategic -p "$args_patch" "${APPLY_FLAGS[@]}"
    note "added '--config app-config.extra.yaml' to Backstage args (pod will restart)"
  else
    note "Backstage args already include app-config.extra.yaml"
  fi
fi

# --------------------------------------------------------------- verification --

log "Verification"
FAIL=0

for ct in api-proxy manual-task mcp-server; do
  "${KC[@]}" get clustercomponenttype "$ct" >/dev/null 2>&1 \
    && note "OK  ComponentType $ct" || { note "MISSING ComponentType $ct"; FAIL=1; }
done
for tr in jwt-auth rate-limit cors mediation autoscaler; do
  "${KC[@]}" get clustertrait "$tr" >/dev/null 2>&1 \
    && note "OK  ClusterTrait $tr" || { note "MISSING ClusterTrait $tr"; FAIL=1; }
done

if $DRY_RUN; then
  note "(dry-run: skipping RBAC effect check — nothing was mutated)"
else
  for res in trafficpolicies backendconfigpolicies gatewayextensions; do
    if [[ "$("${KC[@]}" auth can-i create "$res.gateway.kgateway.dev" \
          --as=system:serviceaccount:openchoreo-data-plane:cluster-agent-dataplane 2>/dev/null)" == "yes" ]]; then
      note "OK  cluster-agent can create $res"
    else
      note "FAIL cluster-agent cannot create $res (policy-bearing components will silently 404)"
      FAIL=1
    fi
  done
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo; echo "Verification FAILED — see lines above." >&2
  exit 1
fi

echo
echo "Done. Cluster now matches the V2-parity POC baseline."
echo "Manual per-cluster steps remain (secrets/identity) — see README.md 'Per-cluster checklist'."
