<div align="center">

# Patina

English · [中文](docs/README.zh-cn.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT) [![Patina CI](https://github.com/clonimai/patina/actions/workflows/patina.yml/badge.svg)](https://github.com/clonimai/patina/actions/workflows/patina.yml)

<img src="https://clonimai.github.io/patina/badge.svg" alt="Craftsmanship">

</div>

**Patina** — originally copper green, then the sheen that years of handling
leaves on objects like antiques and handcrafted pieces. Code ages the same
way: modified, reviewed, and refactored over time, every surviving line
carries a distinct texture. Patina measures the current share of those traces
in your repository.

The score's meaning is yours to define — whether `0.5` means half-human or
AI-draft with human polish is up to you. Patina does not validate: you can
tamper with it freely, but those who don't trust you still won't be
convinced.

## How it works

Each commit carries a `Craft: 0–1` score. CI traces every surviving line back
to its origin commit with `git blame`, then computes a survival-weighted
average.

$$R = \frac{\sum (S_k \times L_k)}{\sum L_k}$$

Where $S_k$ is the Craft score of commit $k$, and $L_k$ is the number of
surviving lines it introduced.

Patina tracks **stock, not flow** — it measures the quality of what's in the
repo right now, not the effort spent writing it. Example: A adds 100 human
lines (1.0) → B adds 100 AI lines (0.0) → C deletes every AI line and adds 10
human lines (1.0). Weighting the three scores by lines changed gives ≈ 0.68 —
yet all 110 current lines are human, which is effectively 100%. The former
counts how it was written (effort); the latter looks at what remains (quality).
Patina takes the latter. Craft is about quality at its core; polishing is only
a means to that end.

```
Craft score on every commit → CI blame aggregation → badge deployed to GitHub Pages
```

Scores are stored as **Git Trailers** at the end of the commit message,
natively parseable by Git. A trailer is a line at the end of the message that
starts with a key:

```
Fix the widget parsing edge case

Craft: 0.95
```

Append it with `--trailer` when committing:

```bash
git commit -m "message" --trailer "Craft: 0.95"
```

> [!NOTE]
> If writing by hand: `Craft:` must be at column 0 (no leading space/tab),
> preceded by a blank line, with no blank lines inside the block and nothing
> after it.

## Quick start

**1. Copy the workflow into your repo** — take this repo's
`.github/workflows/patina.yml` and place it under `.github/workflows/` in your
own (you may rename it):

```yaml
name: Patina

on:
  push:
    branches: [main]  # trigger on every push to main
  workflow_dispatch:  # manual trigger

# consecutive runs cancel the still-running previous one
concurrency:
  group: ${{ github.workflow }}
  cancel-in-progress: true

permissions:
  contents: write  # push the cache to refs/patina
  pages: write     # deploy to GitHub Pages
  id-token: write

jobs:
  craft:
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deploy.outputs.page_url }}

    steps:
      # fetch the remote repo and check it out
      - name: Checkout
        uses: actions/checkout@v7
        with:
          fetch-depth: 0  # full history
          filter: blob:none # blobless, fetch blobs on demand

      # run main.sh from your repo root
      - name: Main
        run: source main.sh

      # package the contents of .patina as an artifact
      - name: Upload artifact
        uses: actions/upload-pages-artifact@v5
        with:
          path: .patina
          # include hidden files and folders
          include-hidden-files: true

      # deploy the uploaded artifact to GitHub Pages
      - name: Deploy to GitHub Pages
        id: deploy
        uses: actions/deploy-pages@v5
```

**2. Place `main.sh` and `badge.svg` wherever you like** — the two reference
each other by relative path: the workflow runs `source main.sh`, and the script
reads `template=badge.svg`. Default: both at the repo root. Subdirectories
work too, but then adjust the `run:` line and `template` together. The badge
template can be your own SVG — the only constraint is that the script replaces
the **first occurrence** of `100%` with the actual percentage.

**3. Enable GitHub Pages** — Settings → Pages → Source: *GitHub Actions*.

> [!NOTE]
> The workflow will overwrite your Pages deployment (merge workflows if you
> already have a Pages site), needs `contents: write`, `pages: write`, and
> `id-token: write` permissions; consecutive triggers cancel the previous run
> still in progress, preventing deploy races.

**4. Write a Craft score on every commit, then hang the badge in your README:**

```markdown
![Craftsmanship](https://<your-user>.github.io/<your-repo>/badge.svg)
```

## Badge

Default template:

[![badge.svg](https://raw.githubusercontent.com/clonimai/patina/main/badge.svg)](badge.svg)

The template is a plain SVG — the **first occurrence** of `100%` is replaced
with the actual percentage. The path is set by the `template` variable at the
top of `main.sh`; colors and text are yours to change.

If any commit tracked by blame is missing a Craft score, the badge degrades to
`—%` — all or nothing.

## Backfilling scores

Forgot a Craft score, or need to score historical commits? Edit the cache
manually.

**How it works**: `refs/patina` is an invisible ref pointing to a commit chain
whose tree contains a single `cache` file. CI reads existing scores from the
cache as a baseline — if a commit has no Craft trailer, it falls back to the
cached value. Cache format:

```
<head> <count> <sum_lines> <weights> <final>    # metadata row
<hash> <lines> <score>                          # data row (empty score = pending)
```

Fill in the missing score at the end of each data row:

```diff
  # data row
- a1b2c3d4... 120
+ a1b2c3d4... 120 0.95
```

**Recommended: use a worktree** to avoid touching your working directory:

> [!NOTE]
> Pull the latest cache before editing — CI force-pushes `refs/patina` on
> every run, so your local ref may be stale. Edit against the newest version
> and resolve any conflicts.

```bash
git fetch origin +refs/patina:refs/patina      # pull the invisible ref (CI may have force-pushed)
git worktree add --detach .patina refs/patina  # check out the cache chain into a separate .patina/ tree
# edit .patina/cache — append the missing score at the end of a data row
git -C .patina add cache                        # stage the cache
git -C .patina commit -m "backfill craft"       # commit, any message works
git -C .patina push origin HEAD:refs/patina --force # push back to refs/patina (force overwrites)
git worktree remove .patina                     # remove the temporary worktree
```

The worktree checks the cache chain out to a separate temporary directory, so
your current branch and uncommitted changes stay untouched. Edit `cache` in
`.patina/`, commit, force-push back to `refs/patina` (the ref may have been
updated by CI, so `--force` overwrites it), then remove the worktree.

`git -C .patina xxx` is equivalent to `cd .patina` followed by `git xxx`;
pick either style:

```bash
cd .patina
git add cache
git commit -m "backfill craft"
git push origin HEAD:refs/patina --force
cd .. && git worktree remove .patina
```

You can also checkout directly, edit, push, and switch back — it just briefly
occupies your working directory. Pre-adoption commits are handled the same
way — backfill them or the badge stays at `—%`.

## FAQ

**Can the score be gamed?** Yes. It's a declaration, not a referee.

**Why does a single missing Craft score cause `—%`?** Patina does not guess.
No score means we don't know — we won't fabricate a number.

**How is this different from Not By AI?** Static badges only declare. Patina
quantifies (0–100%), lives inside the workflow, and updates on every push.

**Will it slow down CI?** Full `git blame` scales with repo size. Incremental
computation and blobless clones keep it lean.

## Architecture

Three files:

```
patina.yml          # CI orchestration (Checkout → Main → Upload → Deploy)
main.sh             # core logic, sourced directly by the workflow
badge.svg           # SVG template — first 100% replaced, path customizable
```

**`main.sh`** — pure Bash with no heavy external dependencies, run via
`source`.

Expected inputs (prepared by the workflow):

| Input | Description |
|---|---|
| Repository | `actions/checkout` (`fetch-depth: 0` + `filter: blob:none`) |
| `badge.svg` | Any path (set by `template` variable at top of `main.sh`), first `100%` replaced |
| Remote `refs/patina` | Invisible ref holding the cache chain (auto-created on first run) |
| `git config user.name/email` | Not set by workflow; script configures `github-actions[bot]` internally |

Ideal output:

```
.patina/
└── badge.svg        # rendered SVG (100% → actual percentage)
```

Side effects:

- Temporarily mounts `.patina/` as a worktree and reads/writes `cache` in it. Once the cache is pushed to the remote, the worktree (with the cache) is removed, leaving only `badge.svg` in `.patina/`
- Pushes `refs/patina` to remote (`--force`, cache chain update)
- Deploys `.patina/` to GitHub Pages (overwrites site content)

## Versions

- **v1** — Full `git blame` scoring + badge generation + GitHub Pages deploy.
- **v2** — `refs/patina` invisible ref cache chain (seed / three-pass validate /
  cache push loop), awk-ized incremental blame pipeline, object warmup,
  incremental-vs-full consistency verified.
- **v3** — `--text` binary blame unification, batched `--batch-check` cache
  validation, CI amend strategy, 12-case test suite.
- **HEAD** — C-style quoted path support, laddered warmup with refetch
  fallback, log system refactor, SIGPIPE fix.

## Planned

- Git hooks — `commit-msg` Craft trailer check; compute average Craft between
  two commits.
- Backfill automation — a CLI wrapper for the manual worktree backfill process
  (manual for now; see Backfilling scores above).

MIT © clonimai
