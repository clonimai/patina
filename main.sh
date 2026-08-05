#!/usr/bin/env bash
set -euo pipefail

template=badge.svg

log()  { echo "patina: $*"; }
elog() { echo "##[error]patina: $*" >&2; }
dlog() { echo "##[debug]patina: $*" >&2; }

patina_setup() {
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

    local seed_tree seed_commit o
    seed_tree=$(git mktree </dev/null)
    seed_commit=$(git commit-tree "$seed_tree" -m "" </dev/null)
    o=$(git ls-remote origin refs/patina)

    if [ -z "$o" ]; then
        git update-ref refs/patina "$seed_commit"
        dlog "refs/patina missing — seeded"
        return
    fi

    git fetch --no-tags origin +refs/patina:refs/remotes/origin/patina
    if git rev-parse --verify refs/remotes/origin/patina^{commit}; then
        git update-ref refs/patina refs/remotes/origin/patina
        dlog "refs/patina synced"
    else
        git update-ref refs/patina "$seed_commit"
        dlog "remote ref not a commit — reseeded"
    fi
}

cache_validate() {
    if [ ! -f .patina/cache ]; then
        log "no cache"
        return
    fi

    prev_cache=$(cat .patina/cache)
    read -r prev_head _ <<< "$prev_cache"

    local l=${#prev_head}
    if [[ ! "$prev_head" =~ ^[0-9a-f]+$ ]] || (( l != 40 && l != 64 )); then
        log "bad cache head"
        return
    fi

    if git merge-base --is-ancestor "$prev_head" HEAD; then
        full_mode=0
        dlog "prev_head is ancestor"
    fi

    if ! awk -v l="$l" '
        function dlog(msg) {
            print "patina: " msg
        }
        NR == 1 {
            count = $2; sum_lines = $3
            if (count !~ /^[0-9]+$/ || sum_lines !~ /^[0-9]+$/) {
                dlog("header count/sum_lines not numeric"); bad = 1
            }
            wd = ($4 == "—"); fd = ($5 == "—")
            wn = ($4 ~ /^[0-9]+(\.[0-9]+)?$/)
            fn = ($5 ~ /^[0-9]+(\.[0-9]+)?$/ && $5 + 0 <= 1)
            if (!((wd && fd) || (wn && fn))) {
                dlog("header weights/final not paired"); bad = 1
            }
            if (bad) exit; next
        }
        {
            if ($1 !~ ("^[0-9a-f]{" l "}$")) {
                dlog("row hash not " l "-hex = " $1); bad = 1
            }
            if ($2 !~ /^[0-9]+$/ || $2 + 0 == 0) {
                dlog("row lines invalid = " $2); bad = 1
            }
            if ($3 != "" && !($3 ~ /^[0-9]+(\.[0-9]+)?$/ && $3 + 0 <= 1)) {
                dlog("row score invalid = " $3); bad = 1
            }
            if (bad) exit; sum += $2
        }
        END {
            if (bad) exit 1
            if (NR == 1) {
                dlog("cache has no commit rows"); exit 1
            }
            if (NR - 1 != count) {
                dlog("count mismatch: got " NR - 1 ", expect " count); exit 1
            }
            if (sum != sum_lines) {
                dlog("sum_lines mismatch: got " sum ", expect " sum_lines); exit 1
            }
        }
    ' <<< "$prev_cache"; then
        full_mode=1
        log "cache integrity failed"
        return
    fi

    if tail -n +2 <<< "$prev_cache" | cut -d' ' -f1 |
        sed 's/$/^{commit}/' |
        git cat-file --batch-check |
        grep -q 'missing$'; then
        full_mode=1
        log "cache has unresolvable commit"
    fi
}

patina_warmup() {
    local floor FLOOR n_blobs
    local -a files

    floor=$(
        tail -n +2 <<< "$prev_cache" | cut -d' ' -f1 |
        git log --no-walk --stdin --format='%H' --reverse |
        sed -n '1p'
    )
    FLOOR=$(git merge-base "$floor" "$prev_head")
    dlog "warmup floor = $floor"
    dlog "warmup FLOOR = $FLOOR"

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
    dlog "warmup number of blobs = $n_blobs"

    if [ "$n_blobs" -lt 100 ]; then
        dlog "warmup skip"
        return
    elif [ "$n_blobs" -lt 1000 ]; then
        dlog "warmup backfill (batch = 100)"
        git backfill --min-batch-size=100 "$FLOOR..HEAD" -- "${files[@]}" && return
        dlog "warmup backfill failed"
    elif [ "$n_blobs" -lt 10000 ]; then
        dlog "warmup backfill (batch = 1000)"
        git backfill --min-batch-size=1000 "$FLOOR..HEAD" -- "${files[@]}" && return
        dlog "warmup backfill failed"
    fi
    dlog "warmup refetch"
    git config --unset remote.origin.partialclonefilter &&
    git fetch --refetch --no-tags --no-write-fetch-head \
        --no-auto-maintenance --no-recurse-submodules origin ||
    dlog "warmup refetch failed — relying on lazy fetch"
}

blames_compute() {
    if [ "$full_mode" != 0 ] || [ -z "$prev_cache" ]; then
        git config --unset remote.origin.partialclonefilter &&
        git fetch --refetch --no-tags --no-write-fetch-head \
            --no-auto-maintenance --no-recurse-submodules origin ||
        dlog "full refetch failed — relying on lazy fetch"
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
        return
    fi

    patina_warmup

    blames=$(
        git diff -U0 --text --no-color --no-renames --no-ext-diff "$prev_head" HEAD |
        awk -v prev_head="$prev_head" '
            $1 == "diff" { f = substr($0, 14, length($0) / 2 - 8) }
            $1 == "@@" {
                sub(/^[-+]/, "", $2); sub(/^[-+]/, "", $3)
                if ($2 !~ /,/) $2 = $2 ",1"
                if ($3 !~ /,/) $3 = $3 ",1"
                split($2, t, ",")
                if (t[2] > 0) old[f] = old[f] " -L " t[1] "," t[1] + t[2] - 1
                split($3, t, ",")
                if (t[2] > 0) new[f] = new[f] " -L " t[1] "," t[1] + t[2] - 1
            }
            END {
                for (f in new)
                    printf "%s\0%s\0%s\0%s\0", "+", new[f], prev_head "..HEAD", f
                for (f in old)
                    printf "%s\0%s\0%s\0%s\0", "-", old[f], prev_head, f
            }
        ' |
        xargs -0 -n 4 bash -c '
            echo "$0"
            git blame --incremental --root $1 "$2" -- "$3"
        ' |
        awk '
            BEGIN { filename = 1 }
            NR==FNR {
                if (NR > 1) lines[$1] = $2
                next
            }
            $1 == "+" || $1 == "-" { side = $1; next }
            $1 == "filename" { filename = 1; next }
            filename {
                if ($1 !~ /^0+$/) lines[$1] += side $4
                filename = 0
            }
            END { for (c in lines) if (lines[c] > 0) print c, lines[c] }
        ' <(echo "$prev_cache") -
    ) || :
}

cache_commit() {
    git -C .patina add cache

    if git -C .patina diff --cached --exit-code; then
        dlog "cache unchanged — skip"
        return
    fi

    if [ "$(git -C .patina show -s --format=%an refs/patina)" = "github-actions[bot]" ]; then
        git -C .patina commit --amend --allow-empty-message -m "" </dev/null
        dlog "cache amended (after CI commit)"
    else
        git -C .patina commit --allow-empty-message -m "" </dev/null
        dlog "cache committed (after human commit)"
    fi

    git -C .patina update-ref refs/patina HEAD
    git -C .patina push --force origin refs/patina:refs/patina
    dlog "cache pushed (force)"
}

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
    log "score = $pct%"
    sed "s/100%/${pct}%/" "$template" > .patina/badge.svg
}

patina_setup

full_mode=1
prev_cache=""
prev_head=""

git worktree add --detach .patina refs/patina
cache_validate
log "mode = $([ "$full_mode" = 0 ] && echo incremental || echo full)"
dlog "prev_cache = $(head -1 <<< "$prev_cache")"

blames=""
blames_compute
if [ -z "$blames" ]; then
    elog "no blamable content"
    exit 1
fi
dlog "blames = $(wc -l <<< "$blames") commits"

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
dlog "scores = $(wc -l <<< "$scores") rows"

cur_head=$(git rev-parse HEAD)

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
dlog "cur_cache = $(head -1 <<< "$cur_cache")"

cache_commit

git worktree remove --force .patina
mkdir -p .patina

badge_generate
