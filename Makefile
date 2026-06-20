DISKJOCKEY_LIB := DiskJockeyLibrary
FILEPROVIDER_PROTOCOL := fileprovider
FILEPROVIDER_PROTO_SRC=${DISKJOCKEY_LIB}/Protobuf/${FILEPROVIDER_PROTOCOL}.proto

# fs-ext4 — pure-Rust ext4 driver vendored as prebuilt static lib + header.
# Source of truth: github.com/christhomas/rust-fs-ext4 (via git submodule)
# pointing at vendor/rust-fs-ext4 (source) → lib/fs_ext4 (built artifacts).
EXT4_SRC := vendor/rust-fs-ext4
EXT4_OUT := lib/fs_ext4

# fs-ntfs — pure-Rust NTFS driver vendored as prebuilt static lib + header.
# Source of truth: github.com/christhomas/rust-fs-ntfs (via git submodule)
# pointing at vendor/rust-fs-ntfs (source) → lib/fs_ntfs (built artifacts).
NTFS_SRC := vendor/rust-fs-ntfs
NTFS_OUT := lib/fs_ntfs

# fs-squashfs — pure-Rust READ-ONLY SquashFS driver vendored as a prebuilt
# static lib + header. Source of truth: github.com/antimatter-studios/rust-fs-squashfs
# (via git submodule) pointing at vendor/rust-fs-squashfs → lib/fs_squashfs.
SQUASHFS_SRC := vendor/rust-fs-squashfs
SQUASHFS_OUT := lib/fs_squashfs

# fs-erofs — pure-Rust READ-ONLY EROFS driver vendored as a prebuilt static
# lib + header. Source of truth: github.com/antimatter-studios/rust-fs-erofs
# (via git submodule) pointing at vendor/rust-fs-erofs → lib/fs_erofs.
EROFS_SRC := vendor/rust-fs-erofs
EROFS_OUT := lib/fs_erofs

# go-networkfs — network filesystem drivers vendored via git submodule.
# Builds per-driver static libs (libftp.a, …) and a combined libnetworkfs.a
# dispatcher, all consumed by the FileProvider extension via cgo.
NETWORKFS_SRC := ./vendor/go-networkfs
NETWORKFS_OUT := lib/go-networkfs
NETWORKFS_DRIVERS := ftp sftp smb dropbox webdav gdrive s3 onedrive


.PHONY: all proto clean \
	vendor-fs-ext4 vendor-fs-ext4-force vendor-fs-ext4-clean \
	vendor-fs-ntfs vendor-fs-ntfs-force vendor-fs-ntfs-clean \
	vendor-fs-squashfs vendor-fs-squashfs-force vendor-fs-squashfs-clean \
	vendor-fs-erofs vendor-fs-erofs-force vendor-fs-erofs-clean \
	vendor-img-containers vendor-img-containers-force vendor-img-containers-clean \
	vendor-gonetworkfs vendor-gonetworkfs-force vendor-gonetworkfs-clean vendor-gonetworkfs-add \
	vendor-bundles vendor-bundles-clean dev-link dev-unlink \
	vendor-all clean-all pins pins-check

# The FS extensions each link ONE per-extension bundle staticlib (driver +
# img readers, built from crates.io). go-networkfs is the separate network-FS
# stack for the FileProvider. The per-crate vendor-fs-*/vendor-img-containers
# targets remain defined for reference/local builds but are no longer linked.
all: vendor-bundles vendor-gonetworkfs proto

proto: proto-fileprovider

proto-fileprovider:
	@echo "\nGenerating fileprovider protocol definitions...\n"
	protoc -I=${DISKJOCKEY_LIB}/Protobuf --swift_opt=Visibility=Public --swift_out=${DISKJOCKEY_LIB}/ $(FILEPROVIDER_PROTO_SRC)

clean: vendor-bundles-clean vendor-fs-ext4-clean vendor-fs-ntfs-clean vendor-fs-squashfs-clean vendor-fs-erofs-clean vendor-img-containers-clean vendor-gonetworkfs-clean
	@echo "\nCleaning up...\n"
	rm -f ./${DISKJOCKEY_LIB}/Protobuf/${FILEPROVIDER_PROTOCOL}.pb.swift

# fs-ext4 is built from vendored source via git submodule at vendor/rust-fs-ext4/.
# The build is handled by scripts/build-fs-ext4.sh which is called both by
# the Makefile (for manual/CI builds) and by Xcode build phases.
# Output: lib/fs_ext4/fs_ext4.xcframework (universal binary + headers)
# Xcode's DiskJockeyEXT4 target links the XCFramework via its bridging header.

# Build fs-ext4 using the shared build script (used by both Makefile and Xcode)
vendor-fs-ext4:
	@echo "\nBuilding fs-ext4 via scripts/build-fs-ext4.sh...\n"
	@SRCROOT=. \
		EXT4_SRC="$(EXT4_SRC)" \
		EXT4_OUT="$(EXT4_OUT)" \
		./scripts/build-fs-ext4.sh

# Force rebuild even if sources haven't changed
vendor-fs-ext4-force:
	@echo "\nForce rebuilding fs-ext4...\n"
	@rm -f $(EXT4_OUT)/.build-stamp
	@$(MAKE) vendor-fs-ext4

vendor-fs-ext4-clean:
	rm -rf $(EXT4_OUT)

# Build fs-ntfs using the shared build script
vendor-fs-ntfs:
	@echo "\nBuilding fs-ntfs via scripts/build-fs-ntfs.sh...\n"
	@SRCROOT=. \
		NTFS_SRC="$(NTFS_SRC)" \
		NTFS_OUT="$(NTFS_OUT)" \
		./scripts/build-fs-ntfs.sh

vendor-fs-ntfs-force:
	@echo "\nForce rebuilding fs-ntfs...\n"
	@rm -f $(NTFS_OUT)/.build-stamp
	@$(MAKE) vendor-fs-ntfs

vendor-fs-ntfs-clean:
	rm -rf $(NTFS_OUT)

# Build fs-squashfs (read-only) using the shared build script
vendor-fs-squashfs:
	@echo "\nBuilding fs-squashfs via scripts/build-fs-squashfs.sh...\n"
	@SRCROOT=. \
		SQUASHFS_SRC="$(SQUASHFS_SRC)" \
		SQUASHFS_OUT="$(SQUASHFS_OUT)" \
		./scripts/build-fs-squashfs.sh

vendor-fs-squashfs-force:
	@echo "\nForce rebuilding fs-squashfs...\n"
	@rm -f $(SQUASHFS_OUT)/.build-stamp
	@$(MAKE) vendor-fs-squashfs

vendor-fs-squashfs-clean:
	rm -rf $(SQUASHFS_OUT)

# Build fs-erofs (read-only) using the shared build script
vendor-fs-erofs:
	@echo "\nBuilding fs-erofs via scripts/build-fs-erofs.sh...\n"
	@SRCROOT=. \
		EROFS_SRC="$(EROFS_SRC)" \
		EROFS_OUT="$(EROFS_OUT)" \
		./scripts/build-fs-erofs.sh

vendor-fs-erofs-force:
	@echo "\nForce rebuilding fs-erofs...\n"
	@rm -f $(EROFS_OUT)/.build-stamp
	@$(MAKE) vendor-fs-erofs

vendor-fs-erofs-clean:
	rm -rf $(EROFS_OUT)

# Disk-image container readers (am-img-qcow2/vhd/vhdx/vmdk). Each crate
# builds to its own universal static lib at lib/img_<name>/. Consumers
# (DiskJockeyEXT4, DiskJockeyNTFS) link each .a individually — they are
# NOT bundled into libfs_ext4.a or libfs_ntfs.a. See
# `feedback_no_cross_domain_bundling` in the project memory for why.
vendor-img-containers:
	@echo "\nBuilding disk-image container libs via scripts/build-img-containers.sh...\n"
	@SRCROOT=. ./scripts/build-img-containers.sh

vendor-img-containers-force:
	@echo "\nForce rebuilding disk-image container libs...\n"
	@rm -f lib/img_qcow2/.build-stamp lib/img_vhd/.build-stamp lib/img_vhdx/.build-stamp lib/img_vmdk/.build-stamp
	@$(MAKE) vendor-img-containers

vendor-img-containers-clean:
	rm -rf lib/img_qcow2 lib/img_vhd lib/img_vhdx lib/img_vmdk

# Per-extension aggregator staticlibs: one lib per FSKit extension combining
# its driver + the img container readers (crates.io), so each extension links
# a single Rust staticlib with std embedded once. See scripts/build-bundles.sh.
vendor-bundles:
	@scripts/build-bundles.sh

vendor-bundles-clean:
	rm -rf lib/bundle_ext4 lib/bundle_ntfs lib/bundle_erofs lib/bundle_squashfs

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

clean-all: clean vendor-fs-ext4-clean vendor-fs-ntfs-clean vendor-fs-squashfs-clean vendor-fs-erofs-clean vendor-gonetworkfs-clean

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
#   make dev-link   FS=ext4               # ext4 | ntfs | erofs | squashfs
#   make dev-link   FS=ext4 EXTRA=am-img-qcow2   # also co-develop a reader
#   make dev-unlink FS=ext4
dev-link:
	@test -n "$(FS)" || { echo "usage: make dev-link FS=<ext4|ntfs|erofs|squashfs> [EXTRA='am-img-qcow2 ...']"; exit 2; }
	@scripts/dev-link.sh $(FS) $(EXTRA)

dev-unlink:
	@test -n "$(FS)" || { echo "usage: make dev-unlink FS=<ext4|ntfs|erofs|squashfs>"; exit 2; }
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

# ---------------------------------------------------------------------------
# Vendor-pin manifest
# ---------------------------------------------------------------------------
#
# Git submodule pins are stored as opaque 160000 "gitlink" entries in the
# superproject tree — invisible in any plain-text file. `make pins`
# materialises those pins into VENDOR_PINS.txt, which is committed so the
# tag + SHA for every vendored submodule is visible from GitHub's file
# view and from a plain `cat` without needing any git commands.
#
# Regenerate + stage alongside every submodule bump. `make pins-check`
# fails if the on-disk file is stale — wire it into CI if/when we have
# CI for this repo.

VENDOR_PINS_FILE := VENDOR_PINS.txt

pins:
	@echo "# Auto-generated by 'make pins'. Do not edit by hand."          > $(VENDOR_PINS_FILE)
	@echo "# Regenerate after every submodule bump + commit alongside it." >> $(VENDOR_PINS_FILE)
	@echo ""                                                               >> $(VENDOR_PINS_FILE)
	@printf "%-24s %-42s %s\n" "submodule" "sha" "ref"                    >> $(VENDOR_PINS_FILE)
	@printf "%-24s %-42s %s\n" "---------" "---" "---"                    >> $(VENDOR_PINS_FILE)
	@git submodule status | awk '{ \
		sha=$$1; sub(/^[- +]/, "", sha); \
		path=$$2; \
		ref=($$3 ? $$3 : "(no ref)"); \
		printf "%-24s %-42s %s\n", path, sha, ref \
	}' >> $(VENDOR_PINS_FILE)
	@echo ""
	@echo "Wrote $(VENDOR_PINS_FILE):"
	@cat $(VENDOR_PINS_FILE)

pins-check: pins
	@if ! git diff --quiet -- $(VENDOR_PINS_FILE); then \
		echo "ERROR: $(VENDOR_PINS_FILE) is out of date. Run 'make pins' and commit the result."; \
		git diff -- $(VENDOR_PINS_FILE); \
		exit 1; \
	fi
	@echo "$(VENDOR_PINS_FILE) is up to date."
