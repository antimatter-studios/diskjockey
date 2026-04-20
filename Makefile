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

# go-networkfs — network filesystem drivers vendored via git submodule.
# Builds per-driver static libs (libftp.a, …) and a combined libnetworkfs.a
# dispatcher, all consumed by the FileProvider extension via cgo.
NETWORKFS_SRC := ./vendor/go-networkfs
NETWORKFS_OUT := lib/go-networkfs
NETWORKFS_DRIVERS := ftp sftp smb dropbox webdav gdrive s3 onedrive


.PHONY: all proto clean \
	vendor-fs-ext4 vendor-fs-ext4-force vendor-fs-ext4-clean \
	vendor-fs-ntfs vendor-fs-ntfs-force vendor-fs-ntfs-clean \
	vendor-gonetworkfs vendor-gonetworkfs-force vendor-gonetworkfs-clean vendor-gonetworkfs-add \
	vendor-all clean-all pins pins-check

all: vendor-fs-ext4 vendor-fs-ntfs vendor-gonetworkfs proto

proto: proto-fileprovider

proto-fileprovider:
	@echo "\nGenerating fileprovider protocol definitions...\n"
	protoc -I=${DISKJOCKEY_LIB}/Protobuf --swift_opt=Visibility=Public --swift_out=${DISKJOCKEY_LIB}/ $(FILEPROVIDER_PROTO_SRC)

clean: vendor-fs-ext4-clean vendor-fs-ntfs-clean vendor-gonetworkfs-clean
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
vendor-all: vendor-fs-ext4 vendor-fs-ntfs vendor-gonetworkfs

clean-all: clean vendor-fs-ext4-clean vendor-fs-ntfs-clean vendor-gonetworkfs-clean

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
