#!/usr/bin/env bash
set -euo pipefail

template=badge.svg  # SVG template: must contain exactly one "100%" placeholder

# GHA-native logging: ##[debug]/##[error] parsed by the runner
log()  { echo "$*"; }
elog() { echo "##[error]$*" >&2; }
dlog() { echo "##[debug]$*" >&2; }

# Ensure refs/patina exists locally as a valid commit: seed if missing, fetch
# if present (reseed when it points at a non-commit object). Identity is
# inlined — the runner has no git user — so the call site stays order-independent.
patina_setup() {
    # Runner lacks a git identity (actions/checkout doesn't set user) — set it
    # up front so commit-tree (seed) works regardless of call-site order.
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

    local o seed_tree seed_commit
    seed_tree=$(git mktree </dev/null)
    seed_commit=$(git commit-tree "$seed_tree" -m "" </dev/null)

    o=$(git ls-remote origin refs/patina)
    if [ -z "$o" ]; then
        # (2) no refs/patina yet → seed with an empty commit and bail
        git update-ref refs/patina "$seed_commit"
        dlog "patina: refs/patina missing — seeded empty commit"
        return
    fi

    # (3) ref present → fetch; reseed if it points at a non-commit object
    git fetch --no-tags origin +refs/patina:refs/remotes/origin/patina
    if git rev-parse --verify refs/remotes/origin/patina^{commit}; then
        # (3a) valid commit → sync the local branch to it
        git update-ref refs/patina refs/remotes/origin/patina
        dlog "patina: refs/patina synced to remote"
    else
        git update-ref refs/patina "$seed_commit"
        dlog "patina: refs/patina not a commit — reseeded empty commit"
    fi
}

# Validate the latest refs/patina cache (caller checks out its tree at .patina)
# in two passes: head shape + ancestry, then integrity. Sets full_mode and
# leaves the working candidate prev_cache / prev_head for the backfill to read.
cache_validate() {
    if [ ! -f .patina/cache ]; then
        dlog "patina: latest commit has no cache — full mode"
        return
    fi

    prev_cache=$(cat .patina/cache)
    prev_head=$(awk 'NR == 1 { print $1; exit }' <<< "$prev_cache")

    # pass 1: head must be a full-length hex hash (40/64); ancestry then decides the mode
    if [[ ! "$prev_head" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
        prev_cache=""
        prev_head=""
        dlog "patina: cache head invalid — full mode"
        return
    fi

    # Ancestor → incremental; otherwise keep the default full_mode=1
    if git merge-base --is-ancestor "$prev_head" HEAD; then
        full_mode=0
    fi

    # pass 2: full integrity check — prev_cache is still the raw file here
    if ! awk -v l="${#prev_head}" '
        NR == 1 {
            count = $2; lines = $3
            if (count !~ /^[0-9]+$/ || lines !~ /^[0-9]+$/) bad = 1
            w = $4; f = $5
            wd = (w == "—"); fd = (f == "—")
            wn = (w ~ /^[0-9]+(\.[0-9]+)?$/)
            fn = (f ~ /^[0-9]+(\.[0-9]+)?$/ && f + 0 <= 1)
            if (!((wd && fd) || (wn && fn))) bad = 1
            if (bad) exit
            next
        }
        {
            if ($1 !~ ("^[0-9a-f]{" l "}$")) bad = 1
            if ($2 !~ /^[0-9]+$/ || $2 + 0 == 0) bad = 1
            if ($3 != "" && !($3 ~ /^[0-9]+(\.[0-9]+)?$/ && $3 + 0 <= 1)) bad = 1
            if (bad) exit
            sum += $2
        }
        END { if (bad || NR - 1 != count || sum != lines) exit 1 }
    ' <<< "$prev_cache"; then
        prev_cache=""
        full_mode=1
        dlog "patina: cache integrity failed — dropped"
    fi
}

# === Patina mode detection — runs before the blob backfill so the mode can
# decide how much history to prefetch. ===
#   full_mode 0 = incremental (stub) | 1 = full
#   prev_cache "" (invalid) | whole file (validated)
#   backfill  human-filled scores from the latest refs/patina cache commit
#   prev_head HEAD recorded in that cache (ancestry check for incremental)

# (1) ensure a valid local refs/patina (seed / fetch / reseed)
patina_setup

# Defaults — patina_setup touches no variables, so init after it.
full_mode=1
backfill=""
prev_head=""
prev_cache=""

# (4) refs/patina is now a valid commit — check out its tree, then validate
# the latest cache (sets full_mode / prev_cache / prev_head)
git worktree add --detach .patina refs/patina
cache_validate

backfill=$(
    awk 'NR > 1 && $3 != "" { printf "%s %.4f\n", $1, $3 }' <<< "$prev_cache"
)
git worktree remove --force .patina
mkdir -p .patina
dlog "patina: full_mode=$full_mode backfill=$(grep -c . <<< "$backfill") prev_head=${prev_head:-none}"

# Blobless checkout (filter: blob:none): batch-prefetch all blobs so the
# full blame below doesn't stall on per-blob lazy fetches. Best-effort;
# on failure blame still works via lazy fetch, just slower.
git backfill || :

# Incremental blame → <hash> <surviving-lines> per commit.
# Chunk header "<full-hash> <final> <orig> <num-lines>"; every chunk ends
# with a "filename" line, so the filename flag = next line is a chunk header.
blames=$(
    git ls-files -z |
    xargs -0 -r -n 1 git blame --incremental --root HEAD -- |
    awk '
        BEGIN { filename = 1 }
        $1 == "filename" { filename = 1; next }
        filename {
            if ($1 !~ /^0+$/) count[$1] += $4
            filename = 0
        }
        END { for (i in count) print i, count[i] }
    '
) || :  # blame fails on empty repo / no commits / all binary — expected

# Empty blames → no blamable content → fallback badge (.patina exists here)
if [ -z "$blames" ]; then
    elog "no blamable content"
    sed "s/100%/—%/" "$template" > .patina/badge.svg
    exit
fi
dlog "blames: unique commits = $(grep -c . <<< "$blames")"

head=$(git rev-parse HEAD)

# Trailer + backfill merged in one pass. git log --no-walk emits one line per
# commit in date order (newest first) — one line per blames commit, so the row
# count matches blames exactly. Blank trailer → look up backfill; still blank
# = unscored (output as empty $2).
mixed=$(
    cut -d' ' -f1 <<< "$blames" |
    xargs -r git log --no-walk \
        --format="%H %(trailers:key=Craft,valueonly=true)" |
    awk '
        NR==FNR { backfill[$1] = $2; next }
        $1 == "" { next }   # skip git log blank separator lines
        {
            score = ($2 ~ /^[0-9]+(\.[0-9]+)?$/ && $2 + 0 <= 1) ? sprintf("%.4f", $2) : ""
            if (score == "") score = backfill[$1]
            print $1, score
        }
    ' <(echo "$backfill") -
)
dlog "mixed: rows = $(grep -c . <<< "$mixed")"

# Cache: header "<head> <count> <lines> <weighted> <final>", then rows
# "<hash> <lines> <score>" (blank score = awaiting backfill). Rows follow the
# mixed (date) order. Header weighted/final are "—" when any commit is unscored.
cache=$(
    awk -v head="$head" '
        NR==FNR { lines[$1] = $2; next }
        {
            score = $2
            row[++k] = $1 " " lines[$1] (score != "" ? " " score : "")
            total += lines[$1]
            if (score != "") weighted += lines[$1] * score
            else missing = 1
        }
        END {
            printf "%s %d %d %s %s\n", head, k, total,
                (missing ? "—" : sprintf("%.4f", weighted)),
                (missing ? "—" : sprintf("%.4f", weighted / total))
            for (i = 1; i <= k; i++) print row[i]
        }
    ' <(echo "$blames") <(echo "$mixed")
)
echo "$cache" > .patina/cache
dlog "cache: rows = $(grep -c . <<< "$cache")"

# Badge: integer percent from header final-score; "—" = unscored → "—%"
pct=$(
    awk '
        NR == 1 {
            if ($5 == "—") print "—"
            else printf "%d\n", $5 * 100
            exit
        }
    ' .patina/cache
)
log "score: $pct%"
sed "s/100%/${pct}%/" "$template" > .patina/badge.svg
