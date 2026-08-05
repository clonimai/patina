<div align="center">

# Patina

English · [中文](docs/README.zh-cn.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT) [![Patina CI](https://github.com/clonimai/patina/actions/workflows/patina.yml/badge.svg)](https://github.com/clonimai/patina/actions/workflows/patina.yml)

<img src="https://clonimai.github.io/patina/badge.svg" alt="Craftsmanship">

</div>

**Patina** — the sheen that forms on objects through years of use and handling.
Code ages the same way: modified, reviewed, and refactored over time, every
surviving line carries traces of human touch. Patina measures how much of that
remains in your repository.

The score is yours to define — whether `0.5` means half-human or AI-draft with
human polish is up to you. The CI script lives in your repo and anyone can
change it. Patina does not validate: those who don't trust you can't be
convinced, and those who trust you don't need to be.

## How it works

Each commit carries a `Craft: 0–1` score. CI traces every surviving line back
to its origin commit with `git blame`, then computes a survival-weighted
average.

$$R = \frac{\sum (S_k \times L_k)}{\sum L_k}$$

Where $S_k$ is the Craft score of commit $k$, and $L_k$ is the number of
surviving lines it introduced.

Patina tracks **stock, not flow**. Example: A adds 100 human lines (1.0) → B
adds 100 AI lines (0.0) → C deletes all AI lines and adds 10 human lines
(1.0). Averaging by commit gives ≈ 0.67, but the repo now has 110 lines, all
human — the correct answer is 100%. Patina weights by surviving lines: deleted
lines vanish from `git blame` and their weight cancels out of both numerator
and denominator. The badge always reflects the current state.

```
Write Craft (trailer at end of message) → CI blame aggregation → deploy badge to Pages
```

Two design choices: scores live as **Git Trailers** at the end of commit
messages, natively parseable by Git (`--trailer`) with no extra infrastructure.
**No per-file scoring** — one 0–1 number per commit.

## Craft convention

A Craft score is a Git trailer on the final line of the commit message:

```
Fix the widget parsing edge case

Craft: 0.95
```

Rules (Git trailer parsing requires all of these):

- At least one blank line separates it from the body. No blank line, no
  recognition.
- The trailer token (`Craft:`) must be at **column 0** — a leading space or tab
  causes the entire line to be ignored.
- No blank lines within the trailer block — a blank line truncates the block
  and everything after it is lost.
- Nothing after the trailer block — any non-trailer line truncates it.
- Value is 0–1 (`0`, `0.5`, `0.95`, `1`).

Use `--trailer` to satisfy the format automatically:

```bash
git commit -m "message" --trailer "Craft: 0.95"
```

## Quick start

Four steps to adopt Patina:

**1. Copy the workflow** to `.github/workflows/patina.yml`:

```yaml
name: Patina

on:
  push:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: ${{ github.workflow }}
  cancel-in-progress: true

permissions:
  contents: write
  pages: write
  id-token: write

jobs:
  craft:
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deploy.outputs.page_url }}

    steps:
      - name: Checkout
        uses: actions/checkout@v7
        with:
          fetch-depth: 0
          filter: blob:none

      - name: Main
        run: source main.sh

      - name: Upload artifact
        uses: actions/upload-pages-artifact@v5
        with:
          path: .patina
          include-hidden-files: true

      - name: Deploy to GitHub Pages
        id: deploy
        uses: actions/deploy-pages@v5
```

**2. Download `main.sh` and `badge.svg`** to your repo root:

```bash
curl -O https://raw.githubusercontent.com/clonimai/patina/main/main.sh \
     -O https://raw.githubusercontent.com/clonimai/patina/main/badge.svg
```

**3. Enable GitHub Pages** — Settings → Pages → Source: *GitHub Actions*. **Note:
this workflow will overwrite your Pages deployment.** If you already have a
Pages site, merge the two deployment workflows yourself.

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

```bash
git fetch origin +refs/patina:refs/patina
git worktree add --detach .patina refs/patina
# edit .patina/cache
git -C .patina add cache
git -C .patina commit --allow-empty-message -m ""
git -C .patina push origin HEAD:refs/patina --force
git worktree remove .patina
```

You can also checkout directly, edit, push, and switch back. Pre-adoption
commits are handled the same way — backfill them or the badge stays at `—%`.

## Notes & limitations

- **Craft format is strict**: `Craft:` must be at column 0 (no leading
  space/tab), preceded by a blank line, with no blank lines inside the block
  and nothing after it. Any violation means it is not recognized.
- **CI permissions**: the workflow needs `contents: write`, `pages: write`,
  and `id-token: write`, plus Pages enabled. **It will overwrite your
  Pages deployment** — merge workflows if you already have a Pages site.
- **Concurrency**: the workflow uses `concurrency` to serialize pushes on the
  same branch, canceling older runs to prevent deployment races.

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

**`main.sh`** — pure Bash, zero external dependencies, runs via `source`
(variables flow across functions, no intermediate files).

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

- Generates a `cache` file in `.patina/` (weighted aggregation cache, overwritten each CI run)
- Pushes `refs/patina` to remote (`--force`, cache chain update)
- Creates and destroys a temporary worktree (`.patina`, cleaned up after)
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
- Backfill automation — command-line wrapper for the manual worktree backfill
  process.

MIT © clonimai
