#!/usr/bin/env bash
# Canonical DiskJockey product scope. This file has no side effects and is
# sourced by every inventory/worktree tool that needs the repository set.
# The two test harnesses are product scope: they host the oracles the drivers
# are validated against, so their defects block driver work. So are the
# Windows drivers and the WinFsp skeleton they share: the same filesystems,
# shipped on the other platform.
# Pipeline infrastructure such as agent-skills belongs to a separate project.
CONSTELLATION_REPOSITORIES=(
    "diskjockey:antimatter-studios/diskjockey"
    "rust-fs-core:antimatter-studios/rust-fs-core"
    "rust-fs-xfs:antimatter-studios/rust-fs-xfs"
    "rust-fs-ext4:antimatter-studios/rust-fs-ext4"
    "rust-fs-btrfs:antimatter-studios/rust-fs-btrfs"
    "rust-fs-erofs:antimatter-studios/rust-fs-erofs"
    "rust-fs-squashfs:antimatter-studios/rust-fs-squashfs"
    "rust-fs-ntfs:antimatter-studios/rust-fs-ntfs"
    "rust-img-qcow2:antimatter-studios/rust-img-qcow2"
    "rust-img-vhd:antimatter-studios/rust-img-vhd"
    "rust-img-vhdx:antimatter-studios/rust-img-vhdx"
    "rust-img-vmdk:antimatter-studios/rust-img-vmdk"
    "rust-disk-partitions:antimatter-studios/rust-disk-partitions"
    "rust-lzo1x:antimatter-studios/rust-lzo1x"
    "rust-blk-probe:antimatter-studios/rust-blk-probe"
    "go-networkfs:antimatter-studios/go-networkfs"
    "fs-windows-test-harness:antimatter-studios/fs-windows-test-harness"
    "fs-linux-test-harness:antimatter-studios/fs-linux-test-harness"
    "rust-fs-bcachefs:antimatter-studios/rust-fs-bcachefs"
    "ext4-win-driver:antimatter-studios/ext4-win-driver"
    "xfs-win-driver:antimatter-studios/xfs-win-driver"
    "erofs-win-driver:antimatter-studios/erofs-win-driver"
    "winfsp-fs-skeleton:antimatter-studios/winfsp-fs-skeleton"
)
