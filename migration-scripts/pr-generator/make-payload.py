#!/usr/bin/env python3
"""
Build the payload.json consumed by open-pr.js.

Collects files from a source-repo checkout, records each one's repo-relative path and
content, and bundles them with the PR metadata.

Usage:
  ./make-payload.py --repo-root ../checkout --github-repo owner/name \
      --glob '*/workload.yaml' --title "Regenerate workload descriptors" \
      --body-file pr-body.md --out payload.json
"""
import argparse, fnmatch, json, os, sys, time


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo-root", required=True, help="checkout to collect files from")
    ap.add_argument("--github-repo", required=True, metavar="OWNER/NAME")
    ap.add_argument("--glob", default="*/workload.yaml",
                    help="repo-relative glob to collect (default: %(default)s)")
    ap.add_argument("--base", default="main", help="base branch (default: %(default)s)")
    ap.add_argument("--branch", help="head branch (default: migration-<epoch>)")
    ap.add_argument("--title", required=True)
    ap.add_argument("--body-file", help="markdown file for the PR body")
    ap.add_argument("--message", help="commit message (default: the title)")
    ap.add_argument("--out", default="payload.json")
    args = ap.parse_args()

    root = os.path.abspath(args.repo_root)
    if not os.path.isdir(root):
        sys.exit(f"not a directory: {root}")

    files = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for fn in filenames:
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root)
            if fnmatch.fnmatch(rel, args.glob):
                with open(full, encoding="utf-8") as fh:
                    files.append({"path": rel.replace(os.sep, "/"), "content": fh.read()})
    if not files:
        sys.exit(f"no files matched {args.glob!r} under {root}")
    files.sort(key=lambda f: f["path"])

    body = ""
    if args.body_file:
        with open(args.body_file, encoding="utf-8") as fh:
            body = fh.read()

    payload = {
        "repo": args.github_repo,
        "base": args.base,
        "branch": args.branch or f"migration-{int(time.time())}",
        "title": args.title,
        "message": args.message or args.title,
        "body": body,
        "files": files,
    }
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh)

    size = os.path.getsize(args.out)
    print(f"{len(files)} file(s) -> {args.out} ({size/1024:.0f} KB)")
    for f in files:
        print(f"  {f['path']}")
    if size > 900_000:
        print("\nWARNING: a ConfigMap caps at ~1 MB. Split the change or drop inlined specs.")


if __name__ == "__main__":
    main()
