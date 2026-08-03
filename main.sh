#!/usr/bin/env bash
set -euo pipefail

template=badge.svg  # SVG template with exactly one "100%" placeholder

# GHA-native logging: ##[debug]/##[error] parsed by the runner
log()  { echo "$*"; }
elog() { echo "##[error]$*" >&2; }
dlog() { echo "##[debug]$*" >&2; }

# Ensure refs/patina exists locally as a valid commit — seed if missing, fetch
# and sync if present (reseed on non-commit). Runner has no git user, set it.
patina_setup() {
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

    local o seed_tree seed_commit
    seed_tree=$(git mktree </dev/null)
    seed_commit=$(git commit-tree "$seed_tree" -m "" </dev/null)

    o=$(git ls-remote origin refs/patina)
    if [ -z "$o" ]; then
        git update-ref refs/patina "$seed_commit"
        dlog "patina: refs/patina missing — seeded empty commit"
        return
    fi

    git fetch --no-tags origin +refs/patina:refs/remotes/origin/patina
    if git rev-parse --verify refs/remotes/origin/patina^{commit}; then
        git update-ref refs/patina refs/remotes/origin/patina
        dlog "patina: refs/patina synced to remote"
    else
        git update-ref refs/patina "$seed_commit"
        dlog "patina: refs/patina not a commit — reseeded empty commit"
    fi
}

# Validate the checked-out cache at .patina/cache in two passes: head shape +
# ancestry (sets full_mode), then integrity (keeps prev_cache or drops it).
cache_validate() {
    local prev_head

    if [ ! -f .patina/cache ]; then
        dlog "patina: latest commit has no cache — full mode"
        return
    fi

    prev_cache=$(cat .patina/cache)
    prev_head=$(awk 'NR == 1 { print $1; exit }' <<< "$prev_cache")

    # pass 1: head must be a full-length hex hash (40/64); ancestry → mode
    if [[ ! "$prev_head" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
        prev_cache=""
        dlog "patina: cache head invalid — full mode"
        return
    fi

    if git merge-base --is-ancestor "$prev_head" HEAD; then
        full_mode=0
    fi

    # pass 2: integrity — header numbers, weighted/final pairing, per-row shape,
    # and count/sum_lines reconciliation must all hold (single exit-1 in END).
    if ! awk -v l="${#prev_head}" '
        NR == 1 {
            count = $2; sum_lines = $3
            if (count !~ /^[0-9]+$/ || sum_lines !~ /^[0-9]+$/) bad = 1
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
        END { if (bad || NR - 1 != count || sum != sum_lines) exit 1 }
    ' <<< "$prev_cache"; then
        prev_cache=""
        full_mode=1
        dlog "patina: cache integrity failed — dropped"
    fi
}

# Commit the updated cache to refs/patina and push it (cache lives only in the
# ref, never the CDN). -C targets the .patina worktree; the push is a top-level
# statement so a failure aborts the run (inside if/then it would be exempt).
cache_commit() {
    git -C .patina add cache
    if git -C .patina diff --cached --exit-code; then
        return   # unchanged — nothing to commit or push
    fi
    git -C .patina commit -m "" </dev/null
    git -C .patina update-ref refs/patina HEAD
    git -C .patina push origin refs/patina:refs/patina
}

# Render the badge from the cur_cache header final-score; "—" → "—%".
badge_generate() {
    local pct
    pct=$(
        awk '
            NR == 1 {
                if ($5 == "—") print "—"
                else printf "%d\n", $5 * 100
                exit
            }
        ' <<< "$cur_cache"
    )
    log "score: $pct%"
    sed "s/100%/${pct}%/" "$template" > .patina/badge.svg
}

# --- Mode detection: valid refs/patina + validated prev_cache → full_mode ---
patina_setup

full_mode=1
prev_cache=""

git worktree add --detach .patina refs/patina
cache_validate

dlog "patina: full_mode=$full_mode"
dlog "patina: prev_cache=$([ -n "$prev_cache" ] && echo valid || echo dropped)"

# Full mode (incremental is a stub): prefetch blobs before the full blame.
git backfill || :

# Surviving lines per commit. `|| :` swallows the expected blame failure on an
# empty repo — the empty check below fails hard on it.
blames=$(
    git ls-files -z |
    xargs -0 -r -n 1 git blame --incremental --root HEAD -- |
    awk '
        BEGIN { filename = 1 }
        $1 == "filename" { filename = 1; next }
        filename {
            if ($1 !~ /^0+$/) lines[$1] += $4
            filename = 0
        }
        END { for (i in lines) print i, lines[i] }
    '
) || :

if [ -z "$blames" ]; then
    elog "no blamable content"
    exit 1
fi
dlog "blames: unique commits = $(grep -c . <<< "$blames")"

# Per-commit scores: trailer Craft, falling back to prev_cache human fills.
scores=$(
    cut -d' ' -f1 <<< "$blames" |
    xargs -r git log --no-walk \
        --format="%H %(trailers:key=Craft,valueonly=true)" |
    awk '
        NR==FNR {
            if (NR > 1 && $3 != "") cache[$1] = sprintf("%.4f", $3)
            next
        }
        $1 == "" { next }
        {
            if ($2 ~ /^[0-9]+(\.[0-9]+)?$/ && $2 + 0 <= 1)
                score = sprintf("%.4f", $2)
            else
                score = cache[$1]
            print $1, score
        }
    ' <(echo "$prev_cache") -
)
dlog "scores: rows = $(grep -c . <<< "$scores")"

cur_head=$(git rev-parse HEAD)

# Assemble the fresh cache into the mounted worktree, then push via the chain.
# Format: header "<head> <count> <sum_lines> <weights> <final>", then rows
# "<hash> <lines> <score>" (blank score = awaiting human fill).
cur_cache=$(
    awk -v head="$cur_head" '
        NR==FNR { lines[$1] = $2; next }
        {
            score = $2
            lns = lines[$1]
            sum_lines += lns
            if (score != "") {
                row[++count] = $1 " " lns " " score
                weights += lns * score
            } else {
                row[++count] = $1 " " lns
                missing = 1
            }
        }
        END {
            printf "%s %d %d %s %s\n", head, count, sum_lines,
                (missing ? "—" : sprintf("%.4f", weights)),
                (missing ? "—" : sprintf("%.4f", weights / sum_lines))
            for (i = 1; i <= count; i++) print row[i]
        }
    ' <(echo "$blames") <(echo "$scores")
)
echo "$cur_cache" > .patina/cache
dlog "cur_cache: rows = $(grep -c . <<< "$cur_cache")"

cache_commit

# Worktree done — tear down, rebuild .patina as the output dir.
git worktree remove --force .patina
mkdir -p .patina

badge_generate
