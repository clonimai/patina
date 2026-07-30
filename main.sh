#!/usr/bin/env bash
# Patina — Git commit craftsmanship score
set -e

mkdir -p .patina

# ── Blame ──────────────────────────────────────────────────────────
git ls-files -z | \
xargs -0 -n 1 git blame HEAD -- 2>/dev/null > .patina/blame_raw

BOUNDARY=$(grep -c '^\^' .patina/blame_raw || true)
N=$(awk '!/^\^/ { print length($1); exit }' .patina/blame_raw)
# defensive: all ^ lines (won't happen on git blame HEAD)
if [ -z "$N" ]; then
  N=$(head -1 .patina/blame_raw | awk '{ print length($1) - 1 }')
fi

# with boundary → blame inflated by 1; trim both sides to N-1
if [ "$BOUNDARY" -gt 0 ]; then
  L=$((N - 1))
else
  L=$N
fi

# strip ^ → truncate to L → count lines per commit
awk -v L="$L" '
  { sha = $1; gsub(/^\^/,"",sha); sha = substr(sha,1,L) }
  sha !~ /^0+$/ { c[sha]++ }
  END { for(s in c) print s, c[s] }
' .patina/blame_raw > .patina/tmp
rm .patina/blame_raw

# ── Craft lookup ───────────────────────────────────────────────────
TMP=$(cat .patina/tmp)
awk '
  NR==FNR { m[$1]=$2; next }
  { print $0, m[$1] }
' <(echo "$TMP" | awk '{print $1}' | \
    xargs -r git log --no-walk --abbrev="$L" \
      --format="%h %(trailers:key=Craft,valueonly=true)" | \
    awk '
      $2 ~ /^[0-9]+(\.[0-9]+)?$/ && $2 + 0 <= 1 {
      $2 = sprintf("%.4f", $2); print
    }') \
  <(echo "$TMP") > .patina/tmp

# ── Score ──────────────────────────────────────────────────────────
SCORE=$(awk '
  { if (NF < 3) exit 0; w += $3 * $2; s += $2 }
  END { if (s > 0) printf "%d\n", w / s * 100 }
' .patina/tmp || true)
rm -f .patina/tmp

# ── Generate Badge ─────────────────────────────────────────────────
if [ -z "$SCORE" ]; then
  sed "s/100%/—%/g" badge.svg > .patina/badge.svg
else
  sed "s/100%/${SCORE}%/g" badge.svg > .patina/badge.svg
fi
