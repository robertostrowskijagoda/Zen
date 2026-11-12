#!/bin/sh
# Lists every Go fuzz target under a folder, for the fuzz step of the Go
# job in .github/workflows/ci.yml:
#
#   sh tool/ci/go_fuzz_targets.sh [FOLDER]      (default: the current one)
#
# One line per target, three fields separated by tabs: the folder of the Go
# module the target belongs to (the nearest go.mod above its file; the
# ironwood copy under third_party is a module of its own, which
# `go test ./...` of the bridge does not enter), the package inside that
# module (./dir, or . for its root) and the target's name. `go test -fuzz`
# takes one package and one target at a time, so the step runs one line each.
#
# Every `func Fuzz…` of every *_test.go file counts, so a target in a new
# file or a new package is fuzzed without anyone listing it. It fails when
# it finds none: a loop over an empty list would end green having fuzzed
# nothing (the file it used to read could have been renamed).
set -eu

root=${1:-.}
tab=$(printf '\t')

list=$(find "$root" -name '*_test.go' -not -path '*/testdata/*' | LC_ALL=C sort |
  while read -r file; do
    dir=$(dirname "$file")
    module=$dir
    while [ ! -f "$module/go.mod" ] && [ "$module" != "$root" ]; do
      module=$(dirname "$module")
    done
    if [ "$dir" = "$module" ]; then
      package=.
    else
      package=./${dir#"$module"/}
    fi
    { grep -oE '^func Fuzz[A-Za-z0-9_]*' "$file" || true; } | cut -d ' ' -f 2 |
      while read -r target; do
        printf '%s%s%s%s%s\n' "$module" "$tab" "$package" "$tab" "$target"
      done
  done)

if [ -z "$list" ]; then
  echo "::error::No Go fuzz target found under $root: the fuzz step would fuzz nothing." >&2
  exit 1
fi
printf '%s\n' "$list"
