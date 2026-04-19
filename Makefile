DISKJOCKEY_BACKEND := diskjockey-backend
DISKJOCKEY_BACKEND_BINARY := diskjockey-backend
DISKJOCKEY_CLI := diskjockey-cli
DISKJOCKEY_CLI_BINARY := djctl
DISKJOCKEY_LIB := DiskJockeyLibrary
FILEPROVIDER_PROTOCOL := fileprovider
BACKEND_PROTOCOL := backend
FILEPROVIDER_PROTO_SRC=${DISKJOCKEY_LIB}/Protobuf/${FILEPROVIDER_PROTOCOL}.proto
BACKEND_PROTO_SRC=${DISKJOCKEY_BACKEND}/proto/${BACKEND_PROTOCOL}.proto

# fs-ext4 — pure-Rust ext4 driver vendored as prebuilt static lib + header.
# Source of truth: github.com/christhomas/rust-fs-ext4 (via git submodule)
# pointing at vendor/rust-fs-ext4 (source) → lib/fs_ext4 (built artifacts).
EXT4_SRC := vendor/rust-fs-ext4
EXT4_OUT := lib/fs_ext4


.PHONY: all proto djb djctl clean vendor-fs-ext4 vendor-fs-ext4-force vendor-fs-ext4-clean vendor-fs-ntfs vendor-fs-ntfs-force vendor-fs-ntfs-clean vendor-gonetworkfs vendor-gonetworkfs-force vendor-gonetworkfs-clean vendor-gonetworkfs-add vendor-all clean-all

all: vendor-fs-ext4 vendor-fs-ntfs proto djb djctl

proto: proto-backend proto-fileprovider

proto-backend:
	@echo "\nGenerating backend protocol definitions...\n"
	protoc -I=${DISKJOCKEY_BACKEND}/proto --swift_opt=Visibility=Public --swift_out=${DISKJOCKEY_LIB}/ $(BACKEND_PROTO_SRC)
	protoc --go_out=./ $(BACKEND_PROTO_SRC)

proto-fileprovider:
	@echo "\nGenerating fileprovider protocol definitions...\n"
	protoc -I=${DISKJOCKEY_LIB}/Protobuf --swift_opt=Visibility=Public --swift_out=${DISKJOCKEY_LIB}/ $(FILEPROVIDER_PROTO_SRC)

djb:
	@echo "\nBuilding ${DISKJOCKEY_BACKEND_BINARY}...\n"
	cd ${DISKJOCKEY_BACKEND} && go mod tidy
	GO111MODULE=on go build -o ./${DISKJOCKEY_BACKEND}/${DISKJOCKEY_BACKEND_BINARY} ./${DISKJOCKEY_BACKEND}

run-djb:
	@echo "\nRunning ${DISKJOCKEY_BACKEND_BINARY}...\n"
	cd ${DISKJOCKEY_BACKEND} && ./${DISKJOCKEY_BACKEND_BINARY} --config-dir=${PWD}

djctl:
	@echo "\nBuilding ${DISKJOCKEY_CLI_BINARY}...\n"
	cd ${DISKJOCKEY_CLI} && go mod tidy
	GO111MODULE=on go build -o ./${DISKJOCKEY_CLI}/${DISKJOCKEY_CLI_BINARY} ./${DISKJOCKEY_CLI}

clean: vendor-fs-ext4-clean vendor-fs-ntfs-clean
	@echo "\nCleaning up...\n"
	rm -f ./${DISKJOCKEY_LIB}/Protobuf/${BACKEND_PROTOCOL}.pb.swift
	rm -f ./${DISKJOCKEY_LIB}/Protobuf/${FILEPROVIDER_PROTOCOL}.pb.swift
	rm -f ./${DISKJOCKEY_BACKEND}/proto/${BACKEND_PROTOCOL}.pb.go
	rm -f ./${DISKJOCKEY_BACKEND}/${DISKJOCKEY_BACKEND_BINARY}
	rm -f ./${DISKJOCKEY_CLI}/${DISKJOCKEY_CLI_BINARY}

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

# fs-ntfs — pure-Rust NTFS driver vendored as prebuilt static lib + header.
# Source of truth: github.com/christhomas/rust-fs-ntfs (via git submodule)
# pointing at vendor/rust-fs-ntfs (source) → lib/fs_ntfs (built artifacts).
NTFS_SRC := vendor/rust-fs-ntfs
NTFS_OUT := lib/fs_ntfs

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

# Go network drivers (for FileProvider backends via cgo)
GO_SRC := ./diskjockey-backend
GO_OUT := lib/go-networkfs

vendor-godrivers:
	@echo "\nBuilding Go drivers via scripts/build-godrivers.sh...\n"
	@SRCROOT=. \
		GO_SRC="$(GO_SRC)" \
		GO_OUT="$(GO_OUT)" \
		./scripts/build-godrivers.sh

# go-networkfs — network filesystem drivers (separate minimal libraries)
# Build individual drivers: ftp, sftp, smb, dropbox, webdav
# Only link what you need - keeps binary size small
NFS_SRC := ./vendor/go-networkfs
NFS_OUT := lib/go-networkfs
NFS_DRIVERS := ftp

vendor-gonetworkfs:
	@echo "\nBuilding go-networkfs drivers ($(NFS_DRIVERS))...\n"
	@SRCROOT=. \
		NFS_SRC="$(NFS_SRC)" \
		NFS_OUT="$(NFS_OUT)" \
		DRIVERS="$(NFS_DRIVERS)" \
		./scripts/build-gonetworkfs.sh

# Force rebuild even if sources haven't changed
vendor-gonetworkfs-force:
	@echo "\nForce rebuilding go-networkfs...\n"
	@rm -f $(NFS_OUT)/.*-stamp
	@$(MAKE) vendor-gonetworkfs

vendor-gonetworkfs-clean:
	rm -rf $(NFS_OUT)

# Add specific driver (e.g., make vendor-gonetworkfs-add DRIVER=sftp)
vendor-gonetworkfs-add:
	@if [ -z "$(DRIVER)" ]; then \
		echo "Usage: make vendor-gonetworkfs-add DRIVER=sftp"; \
		exit 1; \
	fi
	@DRIVERS="$(NFS_DRIVERS) $(DRIVER)" $(MAKE) vendor-gonetworkfs

# Build all vendored dependencies
vendor-all: vendor-fs-ext4 vendor-fs-ntfs vendor-gonetworkfs

clean-all: clean vendor-fs-ext4-clean vendor-fs-ntfs-clean
	@rm -rf $(NFS_OUT)
