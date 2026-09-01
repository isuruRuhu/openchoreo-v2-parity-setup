# App-authored PR generator (`pr-generator/`)

Commits a set of files and opens a pull request **as the Choreo GitHub App**, so the PR is
authored by the app rather than by a human's credentials.

The point of running it in-cluster: the app's RSA private key is only ever available as an
environment variable inside the control plane. This runs a throwaway Job that reads that
variable in-process. **The key is never printed and never copied to a workstation.**

```bash
./make-payload.py --repo-root /tmp/src --github-repo owner/name \
    --glob '*/workload.yaml' --title "..." --body-file body.md --out /tmp/payload.json

./run-pr.sh /tmp/payload.json
```

Target a different environment with env vars:

```bash
KUBE_CONTEXT=choreo-stage-cp NAMESPACE=stage-choreo-system ./run-pr.sh /tmp/payload.json
```

| Variable | Default |
|---|---|
| `KUBE_CONTEXT` | `choreo-dev-cp` |
| `NAMESPACE` | `dev-choreo-system` |
| `DEPLOYMENT` | `dp-cicd` |
| `SERVICE_ACCOUNT` | `sa-choreo-default` |
| `APP_ID_KEY` | `GITHUB_APP_ID` |
| `APP_KEY_KEY` | `CHOREO-GITHUB-APP-PRIVATE-KEY` |

## How it works

1. Reads `deployment/dp-cicd`'s pod spec to discover the **image** and which ConfigMap and
   Secret hold the app id and private key. Nothing is pinned, so this survives redeploys.
   The app id arrives through a bulk `envFrom.configMapRef`, so each referenced ConfigMap
   is probed for the key.
2. Creates a ConfigMap holding `open-pr.js` + `payload.json`, and a Job running
   `node /script/open-pr.js` on that image.
3. `open-pr.js` signs a JWT with the app key, exchanges it for an installation token, then
   uses the **Git Data API** — blobs → tree → commit → ref — so every file lands in **one
   commit**, and creates the branch ref last so the change produces a **single push
   webhook** rather than one per file.
4. Revokes the installation token in a `finally`, and deletes the Job and ConfigMap on exit.

## Notes

- The payload travels as a **ConfigMap volume**, not as command arguments: `kubectl exec`
  puts argv in the request URL and ingress proxies return `414 Request-URI Too Large` on
  anything sizeable. The ceiling is the ConfigMap limit, ~1 MB; `make-payload.py` warns
  above 900 KB.
- The installation token is requested with the **`repositories`** parameter (plural). The
  singular `repository` is not a GitHub parameter — it is silently ignored, and the token
  is then scoped to *every* repository in the installation.
- Opening a PR pushes a branch, which fires the target repo's webhooks. If that repo has
  components wired to a live Choreo environment, expect deliveries. A branch that matches
  no component version will not start a build, but it does produce log noise.
