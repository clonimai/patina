#!/usr/bin/env bash
# Patina craft-score cache pipeline, sourced by CI. State passes through shell
# variables; the cache is distributed via the refs/patina chain, not the CDN.
set -euo pipefail

template=badge.svg  # SVG template with exactly one "100%" placeholder

# GHA-native logging: ##[debug]/##[error] parsed by the runner
log()  { echo "$*"; }
elog() { echo "##[error]$*" >&2; }
dlog() { echo "##[debug]$*" >&2; }

# Make refs/patina a valid local commit: seed when missing, fetch+sync when
# present (reseed if the remote ref is not a commit). The runner has no git
# identity, so it is configured first.
patina_setup() {
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

    local seed_tree seed_commit o
    seed_tree=$(git mktree </dev/null)
    seed_commit=$(git commit-tree "$seed_tree" -m "" </dev/null)
    o=$(git ls-remote origin refs/patina)

    if [ -z "$o" ]; then
        git update-ref refs/patina "$seed_commit"
        dlog "patina: refs/patina missing — seeded"
        return
    fi

    git fetch --no-tags origin +refs/patina:refs/remotes/origin/patina
    if git rev-parse --verify refs/remotes/origin/patina^{commit}; then
        git update-ref refs/patina refs/remotes/origin/patina
        dlog "patina: refs/patina synced"
    else
        git update-ref refs/patina "$seed_commit"
        dlog "patina: remote ref not a commit — reseeded"
    fi
}

# Validate the checked-out cache at .patina/cache: head shape + ancestry decide
# full_mode; integrity keeps prev_cache or drops it (a bad cache → full mode).
cache_validate() {
    if [ ! -f .patina/cache ]; then
        dlog "patina: no cache — full mode"
        return
    fi

    prev_cache=$(cat .patina/cache)
    read -r prev_head _ <<< "$prev_cache"

    # head must be a full-length hex hash; ancestry decides incremental vs full
    if [[ ! "$prev_head" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
        prev_cache=""
        prev_head=""
        dlog "patina: bad cache head — full mode"
        return
    fi

    if git merge-base --is-ancestor "$prev_head" HEAD; then
        full_mode=0
    fi

    # integrity: header numbers, weighted/final pairing, row shapes, and the
    # count/sum_lines reconciliation must all hold (single exit-1 in END)
    if ! awk -v l="${#prev_head}" '
        function dlog(msg) {
            print "##[debug]patina: " msg > "/dev/stderr"
        }
        NR == 1 {
            count = $2; sum_lines = $3
            if (count !~ /^[0-9]+$/ || sum_lines !~ /^[0-9]+$/) {
                dlog("header count/sum_lines not numeric")
                bad = 1
            }
            w = $4; f = $5
            wd = (w == "—"); fd = (f == "—")
            wn = (w ~ /^[0-9]+(\.[0-9]+)?$/)
            fn = (f ~ /^[0-9]+(\.[0-9]+)?$/ && f + 0 <= 1)
            if (!((wd && fd) || (wn && fn))) {
                dlog("header weights/final not paired")
                bad = 1
            }
            if (bad) exit
            next
        }
        {
            if ($1 !~ ("^[0-9a-f]{" l "}$")) {
                dlog("row hash not " l "-hex: " $1)
                bad = 1
            } else if (system("git cat-file -e " $1 "^{commit}") != 0) {
                dlog("row commit not resolvable: " $1)
                bad = 1
            }
            if ($2 !~ /^[0-9]+$/ || $2 + 0 == 0) {
                dlog("row lines invalid: " $2)
                bad = 1
            }
            if ($3 != "" && !($3 ~ /^[0-9]+(\.[0-9]+)?$/ && $3 + 0 <= 1)) {
                dlog("row score invalid: " $3)
                bad = 1
            }
            if (bad) exit
            sum += $2
        }
        END {
            if (bad) exit 1
            if (NR == 1) {
                dlog("cache has no commit rows")
                exit 1
            }
            if (NR - 1 != count) {
                dlog("row count mismatch: got " NR - 1 ", expect " count)
                exit 1
            }
            if (sum != sum_lines) {
                dlog("sum mismatch: got " sum ", expect " sum_lines)
                exit 1
            }
        }
    ' <<< "$prev_cache"; then
        prev_cache=""
        prev_head=""
        full_mode=1
        dlog "patina: cache integrity failed — dropped"
    fi
}

patina_warmup() {
    local floor FLOOR n_blobs batch_size
    local -a files

    floor=$(
        tail -n +2 <<< "$prev_cache" | cut -d' ' -f1 |
        git log --no-walk --stdin --format='%H' --reverse |
        head -1
    )
    FLOOR=$(git merge-base "$floor" "$prev_head")

    mapfile -d '' -t files < <(
        git diff -z --name-only \
        --no-color --no-renames --no-ext-diff \
        "$prev_head" HEAD
    )
    n_blobs=$(
        git rev-list --objects --filter=object:type=blob \
        --filter-provided-objects "$FLOOR..HEAD" -- "${files[@]}" |
        wc -l
    )
    dlog "patina: warmup FLOOR = $FLOOR"
    dlog "patina: warmup number of blobs = $n_blobs"

    if [ "$n_blobs" -lt 100 ]; then
        dlog "patina: warmup skip"
    elif [ "$n_blobs" -ge 10000 ]; then
        dlog "patina: warmup refetch"
        git config --unset remote.origin.partialclonefilter &&
        git fetch --refetch --no-tags --no-write-fetch-head \
            --no-auto-maintenance --no-recurse-submodules origin || :
    else
        batch_size=100
        [ "$n_blobs" -ge 1000 ] && batch_size=1000
        dlog "patina: warmup backfill (batch_size=$batch_size)"
        git backfill --min-batch-size="$batch_size" "$FLOOR..HEAD" -- "${files[@]}" || :
    fi
}

# Commit the updated cache to the refs/patina chain and push it. -C targets the
# worktree; the push is a top-level statement so a failure aborts the run (a
# failing push inside if/then would be exempt from set -e and silently dropped).
# The chain grows only from human commits: amend our own CI commit, append after
# a human one (distinguished by committer email).
cache_commit() {
    git -C .patina add cache

    if git -C .patina diff --cached --exit-code; then
        dlog "patina: cache unchanged — skip"
        return
    fi

    if [ "$(git -C .patina show -s --format=%an refs/patina)" = "github-actions[bot]" ]; then
        git -C .patina commit --amend --allow-empty-message -m "" </dev/null
        dlog "patina: cache amended (after CI commit)"
    else
        git -C .patina commit --allow-empty-message -m "" </dev/null
        dlog "patina: cache committed (after human commit)"
    fi

    git -C .patina update-ref refs/patina HEAD
    git -C .patina push --force origin refs/patina:refs/patina
    dlog "patina: cache pushed (force)"
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

# --- Mode detection: decide full vs incremental, read the previous cache ---
patina_setup

full_mode=1
prev_cache=""

git worktree add --detach .patina refs/patina
cache_validate
dlog "patina: mode = $([ "$full_mode" = 0 ] && echo incremental || echo full)"
dlog "patina: prev_cache = $([ -n "$prev_cache" ] && echo valid || echo empty)"

# Full mode (incremental is a stub): prefetch blobs before the full blame.
git backfill || :

# Surviving lines per commit. The `|| :` absorbs the expected blame failure on
# an empty repo; the empty check below fails hard on it.
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
dlog "patina: blames = $(grep -c . <<< "$blames") commits"

if [ -z "$blames" ]; then
    elog "patina: no blamable content"
    exit 1
fi

# Per-commit scores: trailer Craft, falling back to human-filled prev_cache.
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
dlog "patina: scores = $(grep -c . <<< "$scores") rows"

cur_head=$(git rev-parse HEAD)

# Assemble the fresh cache into the mounted worktree, then push via the chain.
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
dlog "patina: cur_cache = $(grep -c . <<< "$cur_cache") rows"

cache_commit

# Worktree done — tear down, rebuild .patina as the output dir.
git worktree remove --force .patina
mkdir -p .patina

badge_generate
