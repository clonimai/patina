#!/usr/bin/env bash
set -euo pipefail

mkdir -p .patina

# blame all tracked files, keep only hash column
raw=$(
  git ls-files -z |
  xargs -0 -n 1 git blame HEAD -- 2>/dev/null |
  cut -d' ' -f1
)

# hash length: first line total width; if ^ found, blame inflated by 1
len=$(
  awk '
    NR == 1 { l = length($1) }
    /^\^/   { l--; exit }
    END     { print l }
  ' <<< "$raw"
)

# strip ^ → truncate to len → count surviving lines per commit
blames=$(
  awk -v l="$len" '
  { sha = $1; gsub(/^\^/, "", sha); sha = substr(sha, 1, l) }
  sha !~ /^0+$/ { count[sha]++ }
  END { for(i in count) print i, count[i] }
  ' <<< "$raw"
)

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

# survival-weighted average: R = Σ(Craft × lines) / Σ(lines)
score=$(
  awk '
    NR==FNR { scores[$1] = $2; next }
    !($1 in scores) { exit }
    { weights += $2 * scores[$1]; lines += $2 }
    END { if (lines > 0) printf "%d\n", weights / lines * 100 }
  ' <(echo "$scores") <(echo "$blames")
)

if [ -z "$score" ]; then
  sed "s/100%/—%/g" badge.svg > .patina/badge.svg
else
  sed "s/100%/${score}%/g" badge.svg > .patina/badge.svg
fi
