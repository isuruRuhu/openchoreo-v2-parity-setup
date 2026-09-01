#!/usr/bin/env python3
"""
Generate OpenChoreo workload.yaml descriptors from Choreo V2 .choreo/component.yaml.

Walks a source repo, and for every directory containing .choreo/component.yaml writes a
sibling workload.yaml conforming to the openchoreo.dev/v1alpha1 Workload schema.

Schema reference (docs v1.2.x, "Workload" CRD):
  spec.owner.{projectName,componentName}                    both REQUIRED
  spec.endpoints[].{name,displayName,type,port,basePath,visibility,schema}
  spec.dependencies.endpoints[].{project,component,name,visibility,envBindings}
  EndpointVisibility : project | namespace | internal | external
  ConnectionEnvBindings : address | host | port | basePath   (no OAuth2 fields)

Usage:
  ./generate-workloads.py --repo-root ../my-repo --project my-project
  ./generate-workloads.py --repo-root . --project p --no-inline-schema --dry-run
"""
import argparse, io, os, re, sys

try:
    import yaml
except ImportError:
    sys.exit("PyYAML required:  pip install pyyaml")

# Choreo V2 networkVisibilities -> OpenChoreo EndpointVisibility
VISIBILITY = {"Public": "external", "Organization": "namespace", "Project": "project"}
# Choreo V2 endpoint type -> OpenChoreo EndpointType
ENDPOINT_TYPE = {"REST": "HTTP", "GraphQL": "GraphQL", "WS": "Websocket",
                 "Websocket": "Websocket", "GRPC": "gRPC", "TCP": "TCP", "UDP": "UDP"}
# Dependencies accept only these two visibilities (docs: WorkloadConnection.visibility)
DEP_VISIBILITY_OK = {"project", "namespace"}

OAUTH_NOTE = (
    "# NOTE: the Choreo V2 connection also injected CONSUMERKEY / CONSUMERSECRET /\n"
    "#   TOKENURL / CHOREOAPIKEY. OpenChoreo ConnectionEnvBindings supports only\n"
    "#   address/host/port/basePath, so those OAuth2 values must be supplied by a\n"
    "#   platform-authored SecretReference instead.\n")


class Dumper(yaml.SafeDumper):
    """Emit multi-line strings as literal blocks (|) so inlined API specs stay diffable."""


def _str_representer(dumper, data):
    if "\n" in data:
        # any trailing whitespace forces PyYAML back to quoted style
        data = "\n".join(line.rstrip() for line in data.split("\n"))
        return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")
    return dumper.represent_scalar("tag:yaml.org,2002:str", data)


Dumper.add_representer(str, _str_representer)


def parse_resource_ref(ref):
    """service:/<org>/<component>/<version>/<hash>/<VISIBILITY> -> (component, visibility).

    Choreo truncates the component segment (~25 chars), so the returned name may be a
    prefix of the real directory name; resolve_component() handles that.
    """
    m = re.match(r"^service:/([^/]+)/([^/]+)/([^/]+)/([^/]+)/([^/]+)$", ref or "")
    if not m:
        return None, None
    return m.group(2), m.group(5).upper()


def resolve_component(name, components):
    """Exact match, else a unique prefix match (Choreo truncates names in resourceRefs)."""
    if name in components:
        return name, False
    hits = [c for c in components if c.startswith(name)]
    return (hits[0], True) if len(hits) == 1 else (None, False)


def env_var_for(connection_name):
    """Choreo-defined env var for a connection's ServiceURL.

    Verified against the platform's own 'Connection information' output, e.g.
    connection 'metadata-conn-org' -> CHOREO_METADATA_CONN_ORG_SERVICEURL.
    """
    return "CHOREO_" + re.sub(r"[^A-Za-z0-9]+", "_", connection_name).upper() + "_SERVICEURL"


def build_endpoints(comp_dir, cy, inline_schema, warn):
    endpoints = []
    for ep in cy.get("endpoints", []) or []:
        svc = ep.get("service", {}) or {}
        out = {"name": ep.get("name")}
        if ep.get("displayName"):
            out["displayName"] = ep["displayName"]
        src_type = ep.get("type", "REST")
        if src_type not in ENDPOINT_TYPE:
            warn(f"unknown endpoint type {src_type!r}, defaulting to HTTP")
        out["type"] = ENDPOINT_TYPE.get(src_type, "HTTP")
        if svc.get("port") is not None:
            out["port"] = svc["port"]
        else:
            warn(f"endpoint {ep.get('name')!r} has no service.port")
        if svc.get("basePath"):
            out["basePath"] = svc["basePath"]

        vis = []
        for v in ep.get("networkVisibilities", []) or []:
            if v not in VISIBILITY:
                warn(f"unknown networkVisibility {v!r}, dropped")
                continue
            vis.append(VISIBILITY[v])
        # 'project' is implicit on every endpoint; listing it adds nothing
        vis = [v for v in vis if v != "project"]
        if vis:
            out["visibility"] = vis

        spec_file = ep.get("schemaFilePath")
        if spec_file and inline_schema:
            path = os.path.join(comp_dir, spec_file)
            if os.path.exists(path):
                with open(path) as fh:
                    out["schema"] = {"type": "openapi", "content": fh.read()}
            else:
                warn(f"schemaFilePath {spec_file!r} not found, schema omitted")
        elif spec_file:
            warn(f"schemaFilePath {spec_file!r} not inlined (--no-inline-schema)")
        endpoints.append(out)
    return endpoints


def build_dependencies(cy, components, project, warn):
    """Map connectionReferences -> dependencies.endpoints[]. Returns (deps, unmappable[])."""
    deps, unmappable = [], []
    refs = ((cy.get("dependencies") or {}).get("connectionReferences") or [])
    for ref in refs:
        conn_name = ref.get("name", "<unnamed>")
        raw = ref.get("resourceRef", "")
        target_raw, vis_raw = parse_resource_ref(raw)
        if not target_raw:
            unmappable.append((conn_name, f"could not parse resourceRef {raw!r}"))
            continue

        target, by_prefix = resolve_component(target_raw, components)
        if not target:
            unmappable.append((conn_name,
                f"target {target_raw!r} is not a component of this repo (different org, or\n"
                f"#   not migrated), so it cannot be referenced as a workload dependency."))
            continue
        if by_prefix:
            warn(f"connection {conn_name!r}: resolved truncated target "
                 f"{target_raw!r} -> {target!r}")

        visibility = VISIBILITY.get(vis_raw.capitalize()) if vis_raw else None
        if vis_raw == "ORGANIZATION":
            visibility = "namespace"
        elif vis_raw == "PROJECT":
            visibility = "project"
        elif vis_raw == "PUBLIC":
            visibility = "external"

        if visibility not in DEP_VISIBILITY_OK:
            unmappable.append((conn_name,
                f"target {target!r} is exposed at {visibility!r}; workload dependencies accept\n"
                f"#   only 'project' or 'namespace' visibility."))
            continue

        # endpoint name comes from the target component's own descriptor input
        target_eps = []
        tpath = os.path.join(os.path.dirname(components[target]), "component.yaml")
        if os.path.exists(tpath):
            with open(tpath) as fh:
                target_eps = (yaml.safe_load(fh) or {}).get("endpoints", []) or []
        if not target_eps:
            unmappable.append((conn_name, f"could not read endpoints of target {target!r}"))
            continue
        if len(target_eps) > 1:
            warn(f"connection {conn_name!r}: target {target!r} has "
                 f"{len(target_eps)} endpoints, using the first ({target_eps[0].get('name')!r})")

        deps.append({
            "project": project,
            "component": target,
            "name": target_eps[0].get("name"),
            "visibility": visibility,
            "envBindings": {"address": env_var_for(conn_name)},
        })
    return deps, unmappable


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo-root", required=True, help="source repo checkout to walk")
    ap.add_argument("--project", required=True,
                    help="spec.owner.projectName (REQUIRED and IMMUTABLE once the Workload exists)")
    ap.add_argument("--no-inline-schema", action="store_true",
                    help="skip inlining schemaFilePath into schema.content")
    ap.add_argument("--dry-run", action="store_true", help="print paths, write nothing")
    args = ap.parse_args()

    root = args.repo_root
    if not os.path.isdir(root):
        sys.exit(f"not a directory: {root}")

    # component dir name -> path of its .choreo/component.yaml
    components = {}
    for entry in sorted(os.listdir(root)):
        cy_path = os.path.join(root, entry, ".choreo", "component.yaml")
        if os.path.isfile(cy_path):
            components[entry] = cy_path
    if not components:
        sys.exit(f"no */.choreo/component.yaml found under {root}")

    print(f"project : {args.project}")
    print(f"found   : {len(components)} component(s)\n")
    written = 0

    for comp, cy_path in components.items():
        warnings = []
        with open(cy_path) as fh:
            cy = yaml.safe_load(fh) or {}
        comp_dir = os.path.join(root, comp)

        endpoints = build_endpoints(comp_dir, cy, not args.no_inline_schema, warnings.append)
        deps, unmappable = build_dependencies(cy, components, args.project, warnings.append)

        spec = {"owner": {"projectName": args.project, "componentName": comp},
                "endpoints": endpoints}
        if deps:
            spec["dependencies"] = {"endpoints": deps}

        doc = {"apiVersion": "openchoreo.dev/v1alpha1", "kind": "Workload",
               "metadata": {"name": comp}, "spec": spec}

        header = ("# OpenChoreo Workload Descriptor\n"
                  f"# Generated from {comp}/.choreo/component.yaml by\n"
                  "# migration-scripts/workload-generator/generate-workloads.py\n"
                  "# Schema: openchoreo.dev/v1alpha1 Workload (docs v1.2.x)\n")
        for conn, reason in unmappable:
            header += f"#\n# UNMAPPED CONNECTION {conn!r}: {reason}\n"
        if unmappable or deps:
            header += OAUTH_NOTE

        buf = io.StringIO()
        yaml.dump(doc, buf, Dumper=Dumper, sort_keys=False,
                  default_flow_style=False, width=100)
        content = header + buf.getvalue()

        out_path = os.path.join(comp_dir, "workload.yaml")
        status = "would write" if args.dry_run else "wrote"
        if not args.dry_run:
            with open(out_path, "w") as fh:
                fh.write(content)
            written += 1
        print(f"  {status} {comp}/workload.yaml ({len(content)} bytes"
              f"{f', {len(deps)} dep' if deps else ''}"
              f"{f', {len(unmappable)} unmapped' if unmappable else ''})")
        for w in warnings:
            print(f"      warn: {w}")

    print(f"\n{'dry run — nothing written' if args.dry_run else f'{written} file(s) written'}")
    print("Review spec.owner.projectName before committing — it is immutable "
          "once the Workload is created.")


if __name__ == "__main__":
    main()
