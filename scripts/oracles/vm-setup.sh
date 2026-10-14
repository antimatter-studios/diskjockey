#!/usr/bin/env bash
# fs-linux-test-harness's [setup] script (fs-linux-test-harness.toml): runs as
# root INSIDE the VM, and only when it changes. It installs the tools the XFS
# mutation oracle's Linux half needs (scripts/oracles/xfs-mutations-linux.sh):
# xfsprogs for mkfs.xfs, xfs_repair, xfs_logprint and xfs_db, attr and acl for
# the extended attributes and the POSIX ACL it sets and reads back. The
# harness installs nothing of its own, and the host installs none of these.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq xfsprogs attr acl >/dev/null
# Named in the setup log, so a run records which xfsprogs judged it.
mkfs.xfs -V
