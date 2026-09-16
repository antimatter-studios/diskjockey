DISKJOCKEY_LIB := DiskJockeyLibrary
FILEPROVIDER_PROTOCOL := fileprovider
FILEPROVIDER_PROTO_SRC=${DISKJOCKEY_LIB}/Protobuf/${FILEPROVIDER_PROTOCOL}.proto

EXT4_OUT := lib/fs_ext4

NTFS_OUT := lib/fs_ntfs

SQUASHFS_OUT := lib/fs_squashfs

EROFS_OUT := lib/fs_erofs

# go-networkfs — network filesystem drivers vendored via git submodule.
# Builds per-driver static libs (libftp.a, …) and a combined libnetworkfs.a
# dispatcher, all consumed by the FileProvider extension via cgo.
NETWORKFS_SRC ?= ../go-networkfs
# The tag to build, read from SIBLING_PINS.txt rather than repeated here, so
# there is one place to change it.
NETWORKFS_TAG := $(shell awk '$$1=="go-networkfs"{print $$2}' SIBLING_PINS.txt)
NETWORKFS_OUT := lib/go-networkfs
NETWORKFS_DRIVERS := ftp sftp smb dropbox webdav gdrive s3 onedrive

.PHONY: all proto clean \
	vendor-gonetworkfs vendor-gonetworkfs-force vendor-gonetworkfs-clean vendor-gonetworkfs-add \
	vendor-bundles vendor-bundles-clean dev-link dev-unlink \
	vendor-all clean-all

# The FS extensions each link ONE per-extension bundle staticlib (driver +
# img readers, built from crates.io). go-networkfs is the separate network-FS
# stack for the FileProvider. The per-crate build targets
# targets remain defined for reference/local builds but are no longer linked.
all: vendor-bundles vendor-gonetworkfs proto

proto: proto-fileprovider

proto-fileprovider:
	@echo "\nGenerating fileprovider protocol definitions...\n"
	protoc -I=${DISKJOCKEY_LIB}/Protobuf --swift_opt=Visibility=Public --swift_out=${DISKJOCKEY_LIB}/ $(FILEPROVIDER_PROTO_SRC)

clean: vendor-bundles-clean vendor-gonetworkfs-clean
	@echo "\nCleaning up...\n"
	rm -f ./${DISKJOCKEY_LIB}/Protobuf/${FILEPROVIDER_PROTOCOL}.pb.swift

# fs-ext4 is built from vendored source via git submodule at vendor/rust-fs-ext4/.
# The build is handled by scripts/build-fs-ext4.sh which is called both by
# the Makefile (for manual/CI builds) and by Xcode build phases.
# Output: lib/fs_ext4/fs_ext4.xcframework (universal binary + headers)
# Xcode's DiskJockeyEXT4 target links the XCFramework via its bridging header.

# Build fs-ext4 using the shared build script (used by both Makefile and Xcode)
# Force rebuild even if sources haven't changed
# Build fs-ntfs using the shared build script
# Build fs-squashfs (read-only) using the shared build script
# Build fs-erofs (read-only) using the shared build script
# Disk-image container readers (am-img-qcow2/vhd/vhdx/vmdk). Each crate
# builds to its own universal static lib at lib/img_<name>/. Consumers
# (DiskJockeyEXT4, DiskJockeyNTFS) link each .a individually — they are
# NOT bundled into libfs_ext4.a or libfs_ntfs.a. See
# `feedback_no_cross_domain_bundling` in the project memory for why.
# Per-extension aggregator staticlibs: one lib per FSKit extension combining
# its driver + the img container readers (crates.io), so each extension links
# a single Rust staticlib with std embedded once. See scripts/build-bundles.sh.
vendor-bundles:
	@scripts/build-bundles.sh

vendor-bundles-clean:
	rm -rf lib/bundle_ext4 lib/bundle_ntfs lib/bundle_erofs lib/bundle_squashfs lib/bundle_xfs lib/bundle_btrfs

# go-networkfs builds each driver from NETWORKFS_DRIVERS plus a combined libnetworkfs.a
# dispatcher. Xcode build phases may override DRIVERS via env var to trim the
# set if needed; by default we build everything the submodule provides.
vendor-gonetworkfs:
	@echo "\nBuilding go-networkfs drivers ($(NETWORKFS_DRIVERS))...\n"
	@SRCROOT=. \
		NETWORKFS_SRC="$(NETWORKFS_SRC)" \
		NETWORKFS_OUT="$(NETWORKFS_OUT)" \
		DRIVERS="$(NETWORKFS_DRIVERS)" \
		./scripts/build-gonetworkfs.sh

# Force rebuild even if sources haven't changed
vendor-gonetworkfs-force:
	@echo "\nForce rebuilding go-networkfs...\n"
	@rm -f $(NETWORKFS_OUT)/.*-stamp
	@$(MAKE) vendor-gonetworkfs

vendor-gonetworkfs-clean:
	rm -rf $(NETWORKFS_OUT)

# Add a single driver on top of the default set (e.g., make vendor-gonetworkfs-add DRIVER=<name>)
vendor-gonetworkfs-add:
	@if [ -z "$(DRIVER)" ]; then \
		echo "Usage: make vendor-gonetworkfs-add DRIVER=<name>"; \
		exit 1; \
	fi
	@DRIVERS="$(NETWORKFS_DRIVERS) $(DRIVER)" $(MAKE) vendor-gonetworkfs

# Build all vendored dependencies
vendor-all: vendor-bundles vendor-gonetworkfs

clean-all: clean vendor-gonetworkfs-clean

# Install the DiskJockeyAgent LaunchAgent from the DerivedData build (dev only).
# No /Applications copy needed, no admin prompt. Re-run after each build.
install-agent:
	@scripts/install-agent-dev.sh

# ---------------------------------------------------------------------------
# Local co-development of vendored drivers
# ---------------------------------------------------------------------------
# Distribution builds resolve every driver bundle from crates.io (the
# published, proven versions). To hack on a vendored crate's source and test
# it in the app WITHOUT publishing a new version each time, switch a bundle to
# local-dev mode — it overrides the driver + the shared am-fs-core to the
# local vendor/ submodule — then restore the crates.io-clean state before you
# commit or build for distribution. See scripts/dev-link.sh for the rationale.
#   make dev-link   FS=ext4               # ext4 | ntfs | erofs | squashfs | xfs | btrfs
#   make dev-link   FS=ext4 EXTRA=am-img-qcow2   # also co-develop a reader
#   make dev-unlink FS=ext4
dev-link:
	@test -n "$(FS)" || { echo "usage: make dev-link FS=<ext4|ntfs|erofs|squashfs|xfs|btrfs> [EXTRA='am-img-qcow2 ...']"; exit 2; }
	@scripts/dev-link.sh $(FS) $(EXTRA)

dev-unlink:
	@test -n "$(FS)" || { echo "usage: make dev-unlink FS=<ext4|ntfs|erofs|squashfs|xfs|btrfs>"; exit 2; }
	@scripts/dev-unlink.sh $(FS)

# ---------------------------------------------------------------------------
# Installable .app
# ---------------------------------------------------------------------------
#
# `installable` builds a Release-configured DiskJockey.app signed with
# the team's Apple Development certificate — ready to live at
# /Applications/DiskJockey.app instead of being run out of Xcode's
# DerivedData. The .app lands at build/export/DiskJockey.app.
#
# `installable-install` does the same, then copies the result into
# /Applications (prompting first if a previous install is there).
#
# Both delegate to scripts/build-installable.sh; the comment header on
# that script has the full rationale, signing notes, and switching
# guidance for Developer ID / App Store distribution.

installable:
	@scripts/build-installable.sh

installable-install:
	@scripts/build-installable.sh --install
