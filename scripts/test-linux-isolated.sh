#!/usr/bin/env bash
# Must be run as root with ASTER_TEST_ROOT pointing to a Linux build checkout.
# Namespace mounts prevent service fixtures from touching the host installation.
set -euo pipefail
root="${ASTER_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
if [ "${ASTER_INSIDE_TEST_NS:-}" != 1 ]; then
  exec env ASTER_INSIDE_TEST_NS=1 ASTER_TEST_ROOT="$root" unshare --mount --net bash "$0"
fi
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mount --make-rprivate /
mkdir -p "$scratch/usr-upper" "$scratch/usr-work"
mount -t overlay overlay -o "lowerdir=/usr/lib,upperdir=$scratch/usr-upper,workdir=$scratch/usr-work" /usr/lib
mount -t tmpfs tmpfs /var/lib
mount -t tmpfs tmpfs /run
mkdir -p /usr/lib/aster-desktop /var/lib/aster-desktop
cp "$root/.build/aster-core" "$root/.build/aster-bridge" /usr/lib/aster-desktop/
printf 1000 > /var/lib/aster-desktop/owner
ip link set lo up
ip link add aster-dummy type dummy
ip addr add 192.0.2.1/24 dev aster-dummy
ip link set aster-dummy up
ip route add default dev aster-dummy
cd "$root/bridge"
# Go normally stores its temporary test executable in a mode-0700 directory;
# build an executable in the shared fixture directory for UID peer tests.
go test -c -o "$scratch/desktop-tests" ./internal/desktop
chmod 755 "$scratch" "$scratch/desktop-tests"
ASTER_TEST_CORE="$root/.build/aster-core" ASTER_TEST_TUN=isolated-netns "$scratch/desktop-tests" -test.run 'TestRealTunDNSAndCleanup|TestRealPrivilegedServicePeerAndCleanup' -test.v
