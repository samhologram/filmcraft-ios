# Fork notes: FilmCraft for iOS and iPadOS

This repository is a fork of [storytold/filmcraft](https://github.com/storytold/filmcraft) (remote `upstream`),
maintained at [samhologram/filmcraft-ios](https://github.com/samhologram/filmcraft-ios) (remote `origin`). It adds
native iOS/iPadOS apps on top of the unchanged Rust engine. `main` is this fork's main branch.

## The rule

**Never edit upstream files.** Fork work lives only in:

- `apple/` (Rust bridge `apple/bridge`, Swift package `apple/FilmCraftKit`, app `apple/FilmCraft`, tests, scripts, docs)
- `.github/workflows/apple-*.yml` (none yet)
- `FORK.md`

Everything else is upstream's and stays byte-identical, so importing upstream never conflicts. If the engine needs a
change, send it upstream.

## Remotes

- `origin` = git@github.com:samhologram/filmcraft-ios.git (this fork; `main` is our main branch)
- `upstream` = https://github.com/storytold/filmcraft (the original; `apple/scripts/sync-upstream.sh` adds it if missing)

## Resolving the rare conflict

A conflict can only happen if a fork commit touched an upstream file, which the sync script refuses up front. If one
slips through anyway: take upstream's side for every path outside `apple/`, `FORK.md` and
`.github/workflows/apple-*.yml` (`git checkout --theirs -- <path>`), move any fork-only behaviour into `apple/`
(bridge workaround) or send it upstream as a PR, then finish the merge commit. If upstream changed an engine API the
bridge uses, the post-merge bridge gate fails: fix `apple/bridge` in a follow-up commit, never the engine.

## Importing the original code

```bash
apple/scripts/sync-upstream.sh
```

It adds the `upstream` remote if missing, refuses if any upstream file was changed in the fork, merges `upstream/main`
into `main` (merge commit, never rebase), then reruns the bridge gate, the xcframework build and the coverage checks.
Push with `git push origin main` when they pass.

## CI

Upstream's workflows (`.github/workflows/*.yml`) come along with the code. Fork commits carry `[skip ci]` so pushes to
`main` don't start them.

## Building

See `apple/README.md`; the porting recipe is `apple/docs/COOKBOOK.md`.
