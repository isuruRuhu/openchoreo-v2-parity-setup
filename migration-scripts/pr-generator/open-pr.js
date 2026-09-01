// Runs INSIDE a throwaway pod. Commits files and opens a PR *as the GitHub App*.
// Uses the Git Data API (blobs -> tree -> commit -> ref) so all files land in ONE
// commit, and the branch ref is created last -> a single push webhook, not one per file.
// Mirrors dp-cicd's own flow at github.repository.ts:1880-1959.
const crypto = require("crypto");
const fs = require("fs");

const APP_ID = process.env.GITHUB_APP_ID;
let PEM = process.env.GITHUB_APP_PRIVATE_KEY || "";
if (PEM.includes("\\n")) PEM = PEM.replace(/\\n/g, "\n");
const API = "https://api.github.com";
const P = JSON.parse(fs.readFileSync("/script/payload.json", "utf8"));

const b64url = (b) => Buffer.from(b).toString("base64")
  .replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");

function mintJwt() {
  const now = Math.floor(Date.now() / 1000);
  const h = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const p = b64url(JSON.stringify({ iat: now - 60, exp: now + 540, iss: APP_ID }));
  const s = crypto.createSign("RSA-SHA256"); s.update(`${h}.${p}`);
  return `${h}.${p}.${b64url(s.sign(PEM))}`;
}

async function api(token, method, path, body) {
  const res = await fetch(API + path, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "choreo-workload-descriptor-gen",
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const t = await res.text();
  let j = null; try { j = t ? JSON.parse(t) : null; } catch {}
  if (res.status >= 400) throw new Error(`${method} ${path} -> ${res.status} ${t.slice(0, 300)}`);
  return j;
}

(async () => {
  const jwt = mintJwt();
  const [owner, repo] = P.repo.split("/");

  const inst = await api(jwt, "GET", `/repos/${owner}/${repo}/installation`);
  console.log(`installation id=${inst.id} on ${P.repo}`);

  // correct param name (plural) -> token really is scoped to this one repo
  const tk = await api(jwt, "POST", `/app/installations/${inst.id}/access_tokens`,
    { repositories: [repo] });
  const T = tk.token;
  console.log(`token scoped to ${tk.repositories?.length ?? "?"} repo(s), perms=${JSON.stringify(tk.permissions)}`);

  try {
    const baseRef = await api(T, "GET", `/repos/${owner}/${repo}/git/ref/heads/${P.base}`);
    const baseSha = baseRef.object.sha;
    const baseCommit = await api(T, "GET", `/repos/${owner}/${repo}/git/commits/${baseSha}`);
    console.log(`base=${P.base} sha=${baseSha.slice(0, 8)} tree=${baseCommit.tree.sha.slice(0, 8)}`);

    console.log(`creating ${P.files.length} blobs...`);
    const tree = [];
    for (const f of P.files) {
      const blob = await api(T, "POST", `/repos/${owner}/${repo}/git/blobs`,
        { content: Buffer.from(f.content, "utf8").toString("base64"), encoding: "base64" });
      tree.push({ path: f.path, mode: "100644", type: "blob", sha: blob.sha });
      console.log(`  ${f.path}  ${blob.sha.slice(0, 8)}`);
    }

    const newTree = await api(T, "POST", `/repos/${owner}/${repo}/git/trees`,
      { base_tree: baseCommit.tree.sha, tree });
    const commit = await api(T, "POST", `/repos/${owner}/${repo}/git/commits`,
      { message: P.message, tree: newTree.sha, parents: [baseSha] });
    console.log(`commit -> ${commit.sha.slice(0, 8)}`);

    // ref created last => exactly one push webhook delivery for the whole change
    await api(T, "POST", `/repos/${owner}/${repo}/git/refs`,
      { ref: `refs/heads/${P.branch}`, sha: commit.sha });
    console.log(`branch -> ${P.branch}`);

    const pr = await api(T, "POST", `/repos/${owner}/${repo}/pulls`,
      { title: P.title, head: P.branch, base: P.base, body: P.body });
    console.log(`\nPR CREATED: ${pr.html_url}`);
    console.log(`author: ${pr.user.login} (bot=${pr.user.type === "Bot"})`);
  } finally {
    await api(T, "DELETE", "/installation/token").catch(() => {});
    console.log("installation token revoked");
  }
})().catch((e) => { console.error("FATAL:", e.message); process.exit(1); });
