# Workload descriptor generator (`workload-generator/`)

Converts Choreo V2 `.choreo/component.yaml` files into OpenChoreo `workload.yaml`
descriptors. Walks a source-repo checkout and writes a `workload.yaml` beside every
`.choreo/component.yaml` it finds.

```bash
./generate-workloads.py --repo-root /path/to/checkout --project my-project
./generate-workloads.py --repo-root . --project p --dry-run          # print, write nothing
./generate-workloads.py --repo-root . --project p --no-inline-schema # skip OpenAPI inlining
```

`--project` sets `spec.owner.projectName`. It is **required by the schema and immutable
once the Workload is created** — get it right before the PR merges.

## What it maps

| Choreo V2 | OpenChoreo |
|---|---|
| `endpoints[].service.port` / `.basePath` | `spec.endpoints[].port` / `.basePath` |
| `endpoints[].type: REST` | `type: HTTP` (also GraphQL, WS, GRPC, TCP, UDP) |
| `networkVisibilities: Public` | `visibility: [external]` |
| `networkVisibilities: Organization` | `visibility: [namespace]` |
| `networkVisibilities: Project` | omitted — `project` is implicit on every endpoint |
| `endpoints[].schemaFilePath` | `schema.{type,content}`, spec inlined verbatim |
| `dependencies.connectionReferences[]` | `spec.dependencies.endpoints[]` — see below |

Inlined specs are written as literal block scalars (`|`) so they stay readable in a diff
rather than collapsing to one escaped line.

## Connections need review

OpenChoreo dependencies are plain service discovery. `ConnectionEnvBindings` carries only
`address` / `host` / `port` / `basePath` — there is **no equivalent for the Choreo V2 OAuth2
values** (`CONSUMERKEY`, `CONSUMERSECRET`, `TOKENURL`, `CHOREOAPIKEY`). Those need a
platform-authored `SecretReference`. The generator writes a note into any file it affects.

A connection is skipped, with the reason recorded as a comment at the top of the file, when:

- **the target is not a component of this repo** — a different org, or not yet migrated; or
- **the target is only exposed at `external`** — dependencies accept `project` or
  `namespace` visibility only.

Choreo truncates the component segment of a `resourceRef` (around 25 characters), so the
generator resolves the target by exact match first and then by unique prefix, printing a
`warn:` line whenever a prefix match was used. Check those.

**It only maps connections that `component.yaml` actually declares.** A component that
reaches a sibling service by a hardcoded URL in application code produces no dependency —
the generator will not infer one. Those have to be added by hand, along with the code
change to read the injected variable.

## Output shape

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: Workload
metadata:
  name: my-service
spec:
  owner:
    projectName: my-project
    componentName: my-service
  endpoints:
  - name: my-api
    displayName: My Service API
    type: HTTP
    port: 8080
    basePath: /
    visibility:
    - external
```

Schema reference: OpenChoreo docs, **Workload** CRD (v1.2.x).
