#!/usr/bin/env bash
set -euo pipefail

template=badge.svg   # SVG 模板，必须恰好含一处 100% 占位符

mkdir -p .patina

# Logging (##[debug]/##[error] parsed by GHA runner)
log()  { echo "$*"; }
elog() { echo "##[error]$*" >&2; }
dlog() { echo "##[debug]$*" >&2; }

# blame all tracked files, keep only hash column
# stderr visible — binary/submodule failures show in output
raw=$(
  git ls-files -z |
  xargs -0 -r -n 1 git blame HEAD -- |
  cut -d' ' -f1
)
dlog "raw: total blame lines = $(echo "$raw" | wc -l)"

# empty blame → no files, all binary, or no commits → fallback to —%
if [ -z "$raw" ]; then
  elog "no blamable content"
  sed "s/100%/—%/" "$template" > .patina/badge.svg
  exit
fi

# hash length: first line total width; if ^ found, blame inflated by 1
len=$(
  awk '
    NR == 1 { l = length($1) }
    /^\^/   { l--; exit }
    END     { print l }
  ' <<< "$raw"
)
dlog "len: using hash width = $len"

# strip ^ → truncate to len → count surviving lines per commit
blames=$(
  awk -v l="$len" '
  { sha = $1; gsub(/^\^/, "", sha); sha = substr(sha, 1, l) }
  sha !~ /^0+$/ { count[sha]++ }
  END { for(i in count) print i, count[i] }
  ' <<< "$raw"
)
dlog "blames: unique commits = $(echo "$blames" | wc -l)"
unset raw

# look up Craft trailer for each commit, filter valid [0,1] values
scores=$(
  cut -d' ' -f1 <<< "$blames" |
  xargs -r git log --no-walk --abbrev="$len" \
    --format="%h %(trailers:key=Craft,valueonly=true)" |
  awk '
    $2 ~ /^[0-9]+(\.[0-9]+)?$/ && $2 + 0 <= 1 {
      $2 = sprintf("%.4f", $2)
      print
    }
  '
)
dlog "scores: commits with Craft = $(echo "$scores" | wc -l)"

# survival-weighted average: R = Σ(Craft × lines) / Σ(lines)
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
