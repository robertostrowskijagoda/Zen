#!/bin/sh
# Installs packages with apt-get in a CI job, without the recommended ones:
#
#   sh tool/ci/apt_install.sh PACKAGE...
#
# A runner's own resolver can fail to name the Ubuntu archive for an hour
# at a time ("Temporary failure resolving 'azure.archive.ubuntu.com'")
# while public resolvers answer, and every job that installs a package
# fails with it. So an install that failed is tried again with public
# resolvers put before the runner's own, and once more after a pause. Who
# resolved the name changes nothing about what is installed: apt checks
# the archive's signatures.
#
# `apt-get update` ends well even when it reached no archive, and the
# install after it then waits for every package in turn (the Linux build's
# list did not end within its job's 45 minutes). So what the update says
# is read too, and an update that failed is a failed try, with nothing
# installed in it. It failed when
#   - a name could not be resolved (anywhere), or
#   - an archive of Ubuntu or Debian (a host under ubuntu.com or debian.org,
#     the runner's mirror included) could not be connected to, timed out, or
#     answered 5xx: an "Err:" line, or a "Failed to fetch" warning, with
#     that reason on it or on the line after it.
# Nothing else counts: an "Ign:" of an optional index, an "Err:" with a 404
# or a bad signature, and any failure of a third-party repository the
# runner image carries (Microsoft's, Google's) leave a healthy update
# healthy, because the install does not need them.
#
# For the test (tool/ci/test_ci_checks.py): APT_INSTALL_RESOLV_CONF names
# another file than /etc/resolv.conf, APT_INSTALL_PAUSE another pause.
set -u

resolv_conf="${APT_INSTALL_RESOLV_CONF:-/etc/resolv.conf}"
pause="${APT_INSTALL_PAUSE:-30}"

if [ "$#" -eq 0 ]; then
  echo "usage: apt_install.sh PACKAGE..." >&2
  exit 2
fi

as_root() {
  if [ "$(id -u)" = 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

said=$(mktemp)
trap 'rm -f "$said"' EXIT

# The reasons that mean a host cannot be reached (case does not matter).
unreachable='could not connect|connection (timed out|failed|refused|reset)|unable to connect|network is unreachable|cannot initiate the connection|[[:space:]]5[0-9][0-9][[:space:]]+(internal server error|bad gateway|service unavailable|gateway time-?out|server error)'
# A failure line naming an archive of the distribution.
archive_failure='^(Err:[0-9]+|[WE]: Failed to fetch) https?://[^/ ]*(ubuntu\.com|debian\.org)(:[0-9]+)?/'

update_failed() {
  grep -Eq 'Temporary failure resolving|Could not resolve' "$said" ||
    grep -E -A1 "$archive_failure" "$said" | grep -Eiq "$unreachable"
}

update() {
  as_root apt-get update > "$said" 2>&1
  status=$?
  cat "$said"
  [ "$status" -eq 0 ] && ! update_failed
}

update_and_install() {
  update && as_root apt-get install -y --no-install-recommends "$@"
}

update_and_install "$@" && exit 0

echo "::warning::apt-get failed: trying again with public resolvers."
own=$(grep '^nameserver' "$resolv_conf" | head -n 1)
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n%s\n' "$own" |
  as_root tee "$resolv_conf" > /dev/null
update_and_install "$@" && exit 0

echo "::warning::apt-get failed again: one more try in $pause seconds."
sleep "$pause"
update_and_install "$@"
