#!/usr/bin/env bash
set -euo pipefail
MAIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/main.sh"
T=$(mktemp -d)
MODE=$(mktemp /tmp/patina_mode.XXXXXX.sh)
trap 'rm -rf "$T" "$MODE"' EXIT

# Extract the mode-detection section (up to the prev_cache dlog) and append an
# assertion printing full_mode / prev_cache / filled (scored rows in prev_cache).
sed -n '1,/^dlog "patina: prev_cache/p' "$MAIN" > "$MODE"
cat >> "$MODE" <<'ASSERT'
printf 'RESULT full_mode=%s prev_cache=%s filled=%s\n' \
    "$full_mode" \
    "$([ -z "$prev_cache" ] && echo EMPTY || echo KEPT)" \
    "$(awk 'NR > 1 && $3 != "" { n++ } END { print n+0 }' <<< "$prev_cache")"
ASSERT

fail=0
check() {
    local name="$1" em="$2" epe="$3" ef="$4"
    local out got m p f
    out=$(cd "$T/$name/work" && bash "$MODE")
    got=$(grep '^RESULT' <<< "$out")
    m=$(sed -n 's/.*full_mode=\([0-9]\).*/\1/p' <<< "$got")
    p=$(sed -n 's/.*prev_cache=\([A-Z]*\).*/\1/p' <<< "$got")
    f=$(sed -n 's/.*filled=\([0-9]*\).*/\1/p' <<< "$got")
    if [ "$m" = "$em" ] && [ "$p" = "$epe" ] && [ "$f" = "$ef" ]; then
        echo "PASS $name (mode=$m prev=$p filled=$f)"
    else
        echo "FAIL $name (expect mode=$em prev=$epe filled=$ef; got mode=$m prev=$p filled=$f)"
        fail=1
    fi
}

# Fresh repo: bare origin + work checkout on main with one commit.
newrepo() {
    mkdir -p "$T/$1"
    ( cd "$T/$1"
      git init --bare origin.git >/dev/null
      git init -b main work >/dev/null
      cd work
      git config user.name t
      git config user.email t@t
      git remote add origin ../origin.git
      echo hi > f
      git add f
      git commit -m init >/dev/null
      git push origin main >/dev/null
    )
}

# Build a chain commit whose root tree holds one `cache` file (the tree-root
# layout the worktree checkout at .patina maps to .patina/cache). Variants:
#   ok=valid | badhead=head not hex | badshort=head too short (8 hex)
#   | badlines=sum_lines mismatch | badcount=count not numeric
#   | badpair=weights/final pairing broken | badscore=row score invalid
#   | empty=no rows | sha256=64-bit head (is-ancestor 128) | partial=some rows unscored
putcache() {
    ( cd "$T/$1/work"
      local v="$2" h1 h64 body blob tree cc
      h1=$(git rev-parse HEAD)
      h64=$(printf 'a%.0s' {1..64})
      case "$v" in
        ok)       body=$(printf '%s 2 10 4.5000 0.4500\n%s 6 0.5000\n%s 4 0.7500\n' "$h1" "$h1" "$h1") ;;
        badhead)  body=$(printf 'zzz 2 10 4.5000 0.4500\n%s 6 0.5000\n%s 4 0.7500\n' "$h1" "$h1") ;;
        badlines) body=$(printf '%s 2 99 4.5000 0.4500\n%s 6 0.5000\n%s 4 0.7500\n' "$h1" "$h1" "$h1") ;;
        badcount) body=$(printf '%s abc 10 4.5000 0.4500\n%s 6 0.5000\n%s 4 0.7500\n' "$h1" "$h1" "$h1") ;;
        badpair)  body=$(printf '%s 2 10 — 0.4500\n%s 6 0.5000\n%s 4 0.7500\n' "$h1" "$h1" "$h1") ;;
        badshort) body=$(printf 'deadbeef 2 10 4.5000 0.4500\n%s 6 0.5000\n%s 4 0.7500\n' "$h1" "$h1") ;;
        badscore) body=$(printf '%s 2 10 4.5000 0.4500\n%s 6 abc\n%s 4 0.7500\n' "$h1" "$h1" "$h1") ;;
        empty)    body='' ;;
        sha256)   body=$(printf '%s 2 10 4.5000 0.4500\n%s 6 0.5000\n%s 4 0.7500\n' "$h64" "$h64" "$h64") ;;
        partial)  body=$(printf '%s 2 10 4.5000 0.4500\n%s 6 0.5000\n%s 4\n' "$h1" "$h1" "$h1") ;;
      esac
      blob=$(printf '%s' "$body" | git hash-object -w --stdin)
      tree=$(printf '100644 blob %s\tcache\n' "$blob" | git mktree)
      cc=$(git commit-tree "$tree" -p HEAD -m cache </dev/null)
      git update-ref refs/heads/main "$cc"
      # Local bare push rejects refs/patina (funny ref) — push objects via a
      # temporary heads ref, then write the ref in the bare repo.
      git push origin "$cc":refs/heads/tmp >/dev/null
      git --git-dir=../origin.git update-ref refs/patina "$cc"
      git push origin --delete refs/heads/tmp >/dev/null
    )
}

# refs/patina points at a commit whose tree has no cache file.
nocache() {
    ( cd "$T/$1/work"
      git --git-dir=../origin.git update-ref refs/patina "$(git rev-parse HEAD)"
    )
}

newrepo A; check A 1 EMPTY 0      # no refs/patina → seed → no cache → full
newrepo B; putcache B ok;        check B 0 KEPT 2   # valid cache, head ancestor → incremental
newrepo C; putcache C badhead;   check C 1 EMPTY 0  # head not hex → pass1 drop
newrepo D; putcache D badlines;  check D 1 EMPTY 0  # sum_lines mismatch → pass2 drop
newrepo E; nocache E;            check E 1 EMPTY 0  # refs/patina present, no cache → full
newrepo F; putcache F badcount;  check F 1 EMPTY 0  # count not numeric → header bad
newrepo G; putcache G badpair;   check G 1 EMPTY 0  # weights/final pairing broken → header bad
newrepo H; putcache H badshort;  check H 1 EMPTY 0  # 8-hex head → pass1 length reject
newrepo I; putcache I badscore;  check I 1 EMPTY 0  # row score invalid → pass2 drop
newrepo J; putcache J empty;     check J 1 EMPTY 0  # empty cache file → full
newrepo K; putcache K sha256;    check K 1 KEPT 2   # 64-bit head, is-ancestor 128 → full, data kept
newrepo L; putcache L partial;   check L 0 KEPT 1   # partial unscored → incremental, 1 filled

[ "$fail" = 0 ] && echo "ALL PASS"
