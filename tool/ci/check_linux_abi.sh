#!/bin/sh
# Checks that a Linux release bundle runs on the oldest systems Zen
# supports: no binary in it may need a newer glibc (GLIBC_x.y) or
# libstdc++ (GLIBCXX_3.4.z) than the baseline.
#
#   sh tool/ci/check_linux_abi.sh <bundle dir> [glibc baseline] [glibcxx baseline]
#
# The baseline is Ubuntu 22.04 (glibc 2.35, GCC 12's libstdc++ 3.4.30),
# which the release is built on: Ubuntu 22.04+, Debian 12+, Linux Mint 21+
# (docs/INSTALL.md, "Linux"). A binary linked on a newer system picks up newer symbol
# versions (e.g. __isoc23_strtol@GLIBC_2.38) and then fails to start on
# older ones with "GLIBC_2.38 not found". Needs objdump (binutils).
set -eu
export LC_ALL=C

bundle=${1:?usage: check_linux_abi.sh <bundle dir> [glibc] [glibcxx]}
glibc_max=${2:-2.35}
glibcxx_max=${3:-3.4.30}

files=$(find "$bundle" -type f \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \) | sort)
[ -n "$files" ] || {
  echo "::error::no binaries in $bundle" >&2
  exit 1
}

# The highest version of [prefix] (GLIBC_ or GLIBCXX_) the binaries need.
highest() {
  for file in $files; do
    # Not every executable file is ELF (install-desktop-entry.sh).
    if [ "$(head -c 4 "$file" | od -An -c | tr -d ' ')" = '177ELF' ]; then
      objdump -T "$file" 2> /dev/null || true
    fi
  done | grep -o "$1[0-9][0-9.]*" | sed "s/^$1//" | sort -Vu | tail -n 1
}

# Whether version $1 is above $2.
above() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

status=0
glibc=$(highest 'GLIBC_')
glibcxx=$(highest 'GLIBCXX_')
echo "Highest symbol versions: GLIBC_${glibc:-none} (baseline $glibc_max), GLIBCXX_${glibcxx:-none} (baseline $glibcxx_max)"
if [ -n "$glibc" ] && above "$glibc" "$glibc_max"; then
  echo "::error::The bundle needs glibc $glibc, newer than the supported $glibc_max:" >&2
  status=1
fi
if [ -n "$glibcxx" ] && above "$glibcxx" "$glibcxx_max"; then
  echo "::error::The bundle needs libstdc++ GLIBCXX_$glibcxx, newer than the supported $glibcxx_max:" >&2
  status=1
fi
if [ "$status" -ne 0 ]; then
  # Which files need what, to find the culprit.
  for file in $files; do
    if [ "$(head -c 4 "$file" | od -An -c | tr -d ' ')" = '177ELF' ]; then
      need=$(objdump -T "$file" 2> /dev/null | grep -o 'GLIBC[X]*_[0-9][0-9.]*' | sort -Vu | tr '\n' ' ')
      echo "  ${file#"$bundle"/}: $need" >&2
    fi
  done
fi
exit "$status"
