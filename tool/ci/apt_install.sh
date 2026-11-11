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

update_and_install() {
  as_root apt-get update &&
    as_root apt-get install -y --no-install-recommends "$@"
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
