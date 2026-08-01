#!/usr/bin/env bash
set -euo pipefail

template=badge.svg   # SVG template: must contain exactly one "100%" placeholder

mkdir -p .patina

# GHA-native logging: ##[debug]/##[error] parsed by the runner
log()  { echo "$*"; }
elog() { echo "##[error]$*" >&2; }
dlog() { echo "##[debug]$*" >&2; }

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
) || :   # blame fails on empty repo / no commits / all binary — expected

# Empty blames → no blamable content → fallback badge
if [ -z "$blames" ]; then
  elog "no blamable content"
  sed "s/100%/—%/" "$template" > .patina/badge.svg
  exit
fi
dlog "blames: unique commits = $(grep -c . <<< "$blames")"

# Craft trailer per commit (full hash), keep only valid [0,1] values
scores=$(
  cut -d' ' -f1 <<< "$blames" |
  xargs -r git log --no-walk \
    --format="%H %(trailers:key=Craft,valueonly=true)" |
  awk '
    $2 ~ /^[0-9]+(\.[0-9]+)?$/ && $2 + 0 <= 1 {
      $2 = sprintf("%.4f", $2)
      print
    }
  '
)
dlog "scores: commits with Craft = $(grep -c . <<< "$scores")"

# Survival-weighted average: R = Σ(Craft × lines) / Σ(lines)
score=$(
  awk '
    NR==FNR { scores[$1] = $2; next }
    !($1 in scores) { missing = 1; exit }
    { weights += $2 * scores[$1]; lines += $2 }
    END { if (!missing) printf "%d\n", weights / lines * 100 }
  ' <(echo "$scores") <(echo "$blames")
)

if [ -z "$score" ]; then
  log "score: —%"
  sed "s/100%/—%/" "$template" > .patina/badge.svg
else
  log "score: $score%"
  sed "s/100%/${score}%/" "$template" > .patina/badge.svg
fi
