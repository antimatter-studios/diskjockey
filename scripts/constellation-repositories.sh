#!/usr/bin/env bash
# Canonical DiskJockey product scope. This file has no side effects and is
# sourced by every inventory/worktree tool that needs the repository set.
# Pipeline infrastructure such as agent-skills belongs to a separate project.
CONSTELLATION_REPOSITORIES=(
    "diskjockey:antimatter-studios/diskjockey"
    "rust-fs-core:antimatter-studios/rust-fs-core"
    "rust-fs-xfs:antimatter-studios/rust-fs-xfs"
    "rust-fs-ext4:christhomas/rust-fs-ext4"
    "rust-fs-btrfs:antimatter-studios/rust-fs-btrfs"
    "rust-fs-erofs:antimatter-studios/rust-fs-erofs"
    "rust-fs-squashfs:antimatter-studios/rust-fs-squashfs"
    "rust-fs-ntfs:christhomas/rust-fs-ntfs"
    "rust-img-qcow2:antimatter-studios/rust-img-qcow2"
    "rust-img-vhd:antimatter-studios/rust-img-vhd"
    "rust-img-vhdx:antimatter-studios/rust-img-vhdx"
    "rust-img-vmdk:antimatter-studios/rust-img-vmdk"
    "rust-partitions:antimatter-studios/rust-partitions"
    "rust-lzo1x:antimatter-studios/rust-lzo1x"
    "rust-blk-probe:antimatter-studios/rust-blk-probe"
    "go-networkfs:christhomas/go-networkfs"
)
