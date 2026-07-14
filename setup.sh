#!/usr/bin/env bash
# Brings a stock OpenChoreo cluster to V2-parity state (mirrors the POC cluster).
#
# Usage:
#   ./setup.sh --context <kube-context> [--skip-backstage] [--dry-run]
#              [--allow-version-mismatch] [--with-autoscaler-trait]
#
#   --context                 REQUIRED. Never operates on the current kubectl context implicitly.
#   --skip-backstage          Skip the console pieces (use when the Backstage console is not
#                             installed, or to avoid the deploy-patch console restart on a
#                             cluster with live users — coordinate a window otherwise).
#   --dry-run                 Server-side dry-run of every apply/patch; mutates nothing.
#                             Also skips the RBAC preflight battery (nothing is mutated).
#   --allow-version-mismatch  Proceed even if the detected OpenChoreo version is not 1.1.x.
#                             The bundle was validated on 1.1.1; 1.0.x schemas are unverified
#                             and 1.2.x needs revalidation — use at your own risk.
#   --with-autoscaler-trait   Force-install our `autoscaler` trait (and its allowedTraits
#                             wiring) even when a stock `horizontal-pod-autoscaler` ClusterTrait
#                             already exists on the cluster. Default is to skip ours to avoid
#                             two competing HPA traits on the same component types.
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
ALLOW_VERSION_MISMATCH=false
WITH_AUTOSCALER_TRAIT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)                 CONTEXT="${2:?--context needs a value}"; shift 2 ;;
    --skip-backstage)          SKIP_BACKSTAGE=true; shift ;;
    --dry-run)                 DRY_RUN=true; shift ;;
    --allow-version-mismatch)  ALLOW_VERSION_MISMATCH=true; shift ;;
    --with-autoscaler-trait)   WITH_AUTOSCALER_TRAIT=true; shift ;;
    -h|--help)                 grep '^#' "$0" | head -30; exit 0 ;;
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

# --- version gate ----------------------------------------------------------
# This bundle was validated on OpenChoreo 1.1.1. 1.0.x carries unverified CRD
# schemas; 1.2.x is pending revalidation (see UPGRADE-REPLAY.md "Version drift").
# Detect the version from the control-plane controller/API image tag.
OC_VERSION="$(
  "${KC[@]}" -n openchoreo-control-plane get deploy -o jsonpath='{range .items[*].spec.template.spec.containers[*]}{.image}{"\n"}{end}' 2>/dev/null \
    | python3 -c '
import re, sys
best = ""
for line in sys.stdin:
    img = line.strip()
    if not img:
        continue
    m = re.search(r"ghcr\.io/openchoreo/(?:controller|openchoreo-api)[^:]*:v?(\d+\.\d+\.\d+)", img)
    if m:
        best = m.group(1); break
    m = re.search(r"openchoreo[^:]*:v?(\d+\.\d+\.\d+)", img)
    if m and not best:
        best = m.group(1)
print(best)
'
)"
if [[ -z "$OC_VERSION" ]]; then
  note "WARN: could not detect the OpenChoreo version from control-plane image tags."
  if ! $ALLOW_VERSION_MISMATCH; then
    echo "ERROR: OpenChoreo version undetectable; re-run with --allow-version-mismatch to proceed anyway." >&2
    exit 2
  fi
  note "proceeding due to --allow-version-mismatch"
elif [[ "$OC_VERSION" == 1.1.* ]]; then
  note "detected OpenChoreo $OC_VERSION (validated line 1.1.x) — OK"
else
  echo "WARN: detected OpenChoreo $OC_VERSION — this bundle was validated on 1.1.1 only." >&2
  echo "      1.0.x schemas are unverified; 1.2.x is pending revalidation." >&2
  if ! $ALLOW_VERSION_MISMATCH; then
    echo "ERROR: version mismatch — re-run with --allow-version-mismatch to proceed anyway." >&2
    exit 2
  fi
  note "proceeding due to --allow-version-mismatch"
fi

# --- cluster-agent ClusterRole discovery -----------------------------------
# Legacy POC name is cluster-agent-dataplane-openchoreo-data-plane, but other
# installs name it differently. Discover it rather than hardcoding.
CLUSTER_AGENT_ROLE_LEGACY="cluster-agent-dataplane-openchoreo-data-plane"
CA_CANDIDATES="$("${KC[@]}" get clusterroles -o name 2>/dev/null | sed 's#^clusterrole.rbac.authorization.k8s.io/##' | grep -E 'cluster-agent' || true)"
CA_COUNT="$(printf '%s\n' "$CA_CANDIDATES" | grep -c . || true)"
if [[ "$CA_COUNT" -eq 0 ]]; then
  echo "ERROR: no cluster-agent ClusterRole found (expected one matching 'cluster-agent')." >&2
  echo "       Is the data-plane installed on this cluster?" >&2
  exit 1
elif [[ "$CA_COUNT" -eq 1 ]]; then
  CLUSTER_AGENT_ROLE="$(printf '%s\n' "$CA_CANDIDATES" | grep -E 'cluster-agent' | head -1)"
elif printf '%s\n' "$CA_CANDIDATES" | grep -qx "$CLUSTER_AGENT_ROLE_LEGACY"; then
  CLUSTER_AGENT_ROLE="$CLUSTER_AGENT_ROLE_LEGACY"
else
  echo "ERROR: multiple cluster-agent ClusterRoles found and none is the known legacy name." >&2
  echo "       Candidates:" >&2
  printf '         %s\n' $CA_CANDIDATES >&2
  echo "       Cannot pick unambiguously — inspect the cluster and rerun." >&2
  exit 1
fi
note "using cluster-agent ClusterRole: $CLUSTER_AGENT_ROLE"

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

# --- autoscaler-trait clash guard ------------------------------------------
# Some installs ship a stock `horizontal-pod-autoscaler` ClusterTrait. If it is
# present, skip our `autoscaler` trait (and its allowedTraits wiring) so we do
# not stack two competing HPA traits — unless --with-autoscaler-trait forces it.
INSTALL_AUTOSCALER_TRAIT=true
if "${KC[@]}" get clustertrait horizontal-pod-autoscaler >/dev/null 2>&1; then
  if $WITH_AUTOSCALER_TRAIT; then
    note "stock 'horizontal-pod-autoscaler' trait present, but --with-autoscaler-trait set — installing ours anyway"
  else
    note "stock 'horizontal-pod-autoscaler' ClusterTrait present — SKIPPING our 'autoscaler' trait"
    note "  (pass --with-autoscaler-trait to install ours alongside it)"
    INSTALL_AUTOSCALER_TRAIT=false
  fi
fi

# --- RBAC preflight battery ------------------------------------------------
# Verify we can perform every mutation the script will attempt, up front, so a
# permission gap fails once with a consolidated list rather than mid-run.
# Skipped under --dry-run (nothing is mutated). A common cause of failures here
# is a Rancher cluster-member token, which carries almost no cluster-scoped RBAC.
if ! $DRY_RUN; then
  log "Preflight: RBAC permission battery"
  RBAC_MISSING=()
  can_i() {
    # can_i <verb> <resource> [-n <namespace>]
    local verb="$1" resource="$2"; shift 2
    if [[ "$("${KC[@]}" auth can-i "$verb" "$resource" "$@" 2>/dev/null)" != "yes" ]]; then
      RBAC_MISSING+=("$verb $resource ${*:-(cluster-scoped)}")
    fi
  }
  can_i create clustercomponenttypes.openchoreo.dev
  can_i patch  clustercomponenttypes.openchoreo.dev
  can_i create clustertraits.openchoreo.dev
  can_i patch  clusterroles.rbac.authorization.k8s.io
  if ! $SKIP_GATEWAY; then
    can_i create httplistenerpolicies.gateway.kgateway.dev -n openchoreo-data-plane
  fi
  if ! $SKIP_BACKSTAGE; then
    can_i patch  deployments.apps -n openchoreo-control-plane
    can_i create configmaps        -n openchoreo-control-plane
  fi
  if [[ "${#RBAC_MISSING[@]}" -gt 0 ]]; then
    echo "ERROR: missing the following RBAC grants on context '$CONTEXT':" >&2
    for m in "${RBAC_MISSING[@]}"; do echo "  - cannot $m" >&2; done
    echo "  A common cause is a Rancher cluster-member token (little/no cluster-scoped RBAC);" >&2
    echo "  obtain a cluster-owner/admin kubeconfig and retry." >&2
    exit 1
  fi
  note "all required grants present"
fi

# ------------------------------------------------- new cluster-scoped objects --

log "Applying custom ComponentTypes (api-proxy, manual-task, mcp-server)"
"${KC[@]}" apply "${APPLY_FLAGS[@]}" -f "$SCRIPT_DIR/component-types/"

if $INSTALL_AUTOSCALER_TRAIT; then
  log "Applying ClusterTraits (jwt-auth, rate-limit, cors, mediation, autoscaler)"
  "${KC[@]}" apply "${APPLY_FLAGS[@]}" -f "$SCRIPT_DIR/traits/"
else
  log "Applying ClusterTraits (jwt-auth, rate-limit, cors, mediation — autoscaler skipped)"
  # Apply each trait file individually, omitting the autoscaler trait (clash guard).
  for f in "$SCRIPT_DIR"/traits/*.yaml; do
    case "$f" in
      */autoscaler-trait.yaml) continue ;;
    esac
    "${KC[@]}" apply "${APPLY_FLAGS[@]}" -f "$f"
  done
fi

if ! $SKIP_GATEWAY; then
  log "Applying WebSocket upgrade HTTPListenerPolicy (data-plane gateway)"
  "${KC[@]}" apply "${APPLY_FLAGS[@]}" -f "$SCRIPT_DIR/gateway/"
fi

# --------------------------------------- patches to chart-shipped objects --
# These edit objects the OpenChoreo Helm charts own. They are re-applied
# (converged) on every run; `helm upgrade` may revert them — re-run this script.

# Exit 0 iff the discovered cluster-agent ClusterRole grants all three kgateway
# policy resources. Reused at the patch step and in final verification (so
# verification needs no impersonation).
cluster_agent_has_kgateway_rule() {
  "${KC[@]}" get clusterrole "$CLUSTER_AGENT_ROLE" -o json 2>/dev/null | python3 -c '
import json, sys
need = {"backendconfigpolicies", "trafficpolicies", "gatewayextensions"}
rules = (json.load(sys.stdin).get("rules") or [])
have = set()
for r in rules:
    if "gateway.kgateway.dev" in (r.get("apiGroups") or []):
        have |= set(r.get("resources") or [])
sys.exit(0 if need <= have else 1)
'
}

log "Ensuring cluster-agent ClusterRole covers kgateway policy CRDs"
if cluster_agent_has_kgateway_rule; then
  note "rule already present — skipping"
else
  "${KC[@]}" patch clusterrole "$CLUSTER_AGENT_ROLE" \
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
if $INSTALL_AUTOSCALER_TRAIT; then
  ensure_allowed_traits service         jwt-auth rate-limit cors mediation autoscaler
  ensure_allowed_traits web-application rate-limit cors mediation autoscaler
  ensure_allowed_traits worker          autoscaler
else
  # autoscaler trait skipped (clash guard) — do not wire it into allowedTraits.
  ensure_allowed_traits service         jwt-auth rate-limit cors mediation
  ensure_allowed_traits web-application rate-limit cors mediation
  note "worker: autoscaler trait skipped — no parity traits to add"
fi
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
PARITY_TRAITS="jwt-auth rate-limit cors mediation"
if $INSTALL_AUTOSCALER_TRAIT; then PARITY_TRAITS="$PARITY_TRAITS autoscaler"; fi
for tr in $PARITY_TRAITS; do
  "${KC[@]}" get clustertrait "$tr" >/dev/null 2>&1 \
    && note "OK  ClusterTrait $tr" || { note "MISSING ClusterTrait $tr"; FAIL=1; }
done
if ! $INSTALL_AUTOSCALER_TRAIT; then
  note "SKIP ClusterTrait autoscaler (clash guard — stock horizontal-pod-autoscaler present)"
fi

if $DRY_RUN; then
  note "(dry-run: skipping RBAC effect check — nothing was mutated)"
else
  # Direct read of the ClusterRole rules — impersonation (auth can-i --as) is
  # frequently denied, so it is not authoritative here. This asserts the three
  # kgateway policy resources are actually granted on the role we patched.
  if cluster_agent_has_kgateway_rule; then
    note "OK  $CLUSTER_AGENT_ROLE grants kgateway trafficpolicies/backendconfigpolicies/gatewayextensions"
  else
    note "FAIL $CLUSTER_AGENT_ROLE is missing a kgateway policy resource (policy-bearing components will silently 404)"
    FAIL=1
  fi
  # Optional extra: an impersonation probe. Warn-only — never fails the run,
  # since impersonating a service account is commonly disallowed.
  ca_sa="$("${KC[@]}" -n openchoreo-data-plane get serviceaccount -o name 2>/dev/null \
            | sed 's#^serviceaccount/##' | grep -E 'cluster-agent' | head -1 || true)"
  if [[ -n "$ca_sa" ]]; then
    imp_ok=true
    for res in trafficpolicies backendconfigpolicies gatewayextensions; do
      [[ "$("${KC[@]}" auth can-i create "$res.gateway.kgateway.dev" \
            --as="system:serviceaccount:openchoreo-data-plane:$ca_sa" 2>/dev/null)" == "yes" ]] || imp_ok=false
    done
    if $imp_ok; then
      note "OK  (extra) impersonation probe confirms $ca_sa can create the policy CRDs"
    else
      note "WARN (extra) impersonation probe inconclusive — impersonation likely disallowed; the rule read above is authoritative"
    fi
  fi
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo; echo "Verification FAILED — see lines above." >&2
  exit 1
fi

echo
echo "Done. Cluster now matches the V2-parity POC baseline."
echo "Manual per-cluster steps remain (secrets/identity) — see README.md 'Per-cluster checklist'."
