# Choreo V2 → OpenChoreo migration scripts (`migration-scripts/`)

Two tools used when moving a Choreo V2 source repo onto OpenChoreo:

| Directory | What it does |
|---|---|
| [`workload-generator/`](workload-generator/) | Turns every `<component>/.choreo/component.yaml` into an OpenChoreo `workload.yaml` descriptor. |
| [`pr-generator/`](pr-generator/) | Commits the result and opens a PR **as the Choreo GitHub App**, without the app private key ever leaving the cluster. |

They are deliberately separate: the generator is a pure local transform you can inspect and
re-run freely, and nothing reaches GitHub until you run the second tool.

## End-to-end

```bash
# 1. Generate descriptors into a checkout of the SOURCE repo
git clone git@github.com:<owner>/<source-repo>.git /tmp/src
./workload-generator/generate-workloads.py --repo-root /tmp/src --project <project-name>

# 2. Review — this is the moment to check spec.owner.projectName
git -C /tmp/src diff

# 3. Bundle the changed files plus the PR text
./pr-generator/make-payload.py \
    --repo-root /tmp/src \
    --github-repo <owner>/<source-repo> \
    --glob '*/workload.yaml' \
    --title "Regenerate OpenChoreo workload descriptors" \
    --body-file my-pr-body.md \
    --out /tmp/payload.json

# 4. Open the PR as the GitHub App
./pr-generator/run-pr.sh /tmp/payload.json
```

## Requirements

- `python3` with **PyYAML** (`pip install pyyaml`) — generator and payload builder.
- `kubectl` + `jq`, with access to a Choreo control-plane cluster and RBAC to create and
  delete `jobs` and `configmaps` in the CP namespace — PR generator only.
- The **Choreo GitHub App installed on the target repository**. It cannot touch a repo it
  is not installed on.

## Cluster footprint

`run-pr.sh` creates one ConfigMap and one Job, then deletes both (with a
`ttlSecondsAfterFinished: 300` backstop). It never modifies the running `dp-cicd`
deployment — it only reads its pod spec to discover the image and the config/secret names.
