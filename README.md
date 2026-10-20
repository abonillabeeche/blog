# blog.5glinux.com

Hugo + PaperMod. Posts are Markdown page bundles under `content/posts/<slug>/index.md`.

## Write
```
hugo new posts/<slug>/index.md     # starts as draft: true
hugo server -D                     # preview at http://localhost:1313 (drafts included)
```

## Publish
1. Branch, write, open a PR. CI runs the blocklist check, a strict build and a link check;
   Cloudflare Pages posts a preview URL on the PR.
2. Set `draft: false` and merge. `main` is what's live.
3. Cross-post (dev.to, LinkedIn) with the canonical URL pointing back here.

## Blocklist
`scripts/check-blocklist.sh` fails the build if a post names something that must not be
published. The terms are never committed: locally they live in `.blocklist` (gitignored),
in CI in the `BLOCKLIST` repository secret (one term per line).
