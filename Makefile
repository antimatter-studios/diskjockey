DISKJOCKEY_BACKEND := diskjockey-backend
DISKJOCKEY_BACKEND_BINARY := diskjockey-backend
DISKJOCKEY_CLI := diskjockey-cli
DISKJOCKEY_CLI_BINARY := djctl
DISKJOCKEY_LIB := DiskJockeyLibrary
FILEPROVIDER_PROTOCOL := fileprovider
BACKEND_PROTOCOL := backend
FILEPROVIDER_PROTO_SRC=${DISKJOCKEY_LIB}/Protobuf/${FILEPROVIDER_PROTOCOL}.proto
BACKEND_PROTO_SRC=${DISKJOCKEY_BACKEND}/proto/${BACKEND_PROTOCOL}.proto

# ext4rs — pure-Rust ext4 driver vendored as prebuilt static lib + header.
# Source of truth: github.com/christhomas/rust-ext4fs (via git submodule)
EXT4RS_SRC := vendor/ext4rs-src
EXT4RS_VENDOR := vendor/ext4rs


.PHONY: all proto djb djctl clean vendor-ext4rs vendor-ext4rs-clean

all: vendor-ext4rs proto djb djctl

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

clean: vendor-ext4rs-clean
	@echo "\nCleaning up...\n"
	rm -f ./${DISKJOCKEY_LIB}/Protobuf/${BACKEND_PROTOCOL}.pb.swift
	rm -f ./${DISKJOCKEY_LIB}/Protobuf/${FILEPROVIDER_PROTOCOL}.pb.swift
	rm -f ./${DISKJOCKEY_BACKEND}/proto/${BACKEND_PROTOCOL}.pb.go
	rm -f ./${DISKJOCKEY_BACKEND}/${DISKJOCKEY_BACKEND_BINARY}
	rm -f ./${DISKJOCKEY_CLI}/${DISKJOCKEY_CLI_BINARY}

# ext4rs is built from vendored source via git submodule at vendor/ext4rs-src/.
# The build is handled by scripts/build-ext4rs.sh which is called both by
# the Makefile (for manual/CI builds) and by Xcode build phases.
# Output: vendor/ext4rs/ext4rs.xcframework (universal binary + headers)
# Xcode's DiskJockeyEXT4 target links the XCFramework via its bridging header.

# Build ext4rs using the shared build script (used by both Makefile and Xcode)
vendor-ext4rs:
	@echo "\nBuilding ext4rs via scripts/build-ext4rs.sh...\n"
	@SRCROOT=. \
		EXT4RS_SRC="$(EXT4RS_SRC)" \
		EXT4RS_OUT="$(EXT4RS_VENDOR)" \
		./scripts/build-ext4rs.sh

# Force rebuild even if sources haven't changed
vendor-ext4rs-force:
	@echo "\nForce rebuilding ext4rs...\n"
	@rm -f $(EXT4RS_VENDOR)/.build-stamp
	@$(MAKE) vendor-ext4rs

vendor-ext4rs-clean:
	rm -rf $(EXT4RS_VENDOR)

# Go network drivers (for FileProvider backends via cgo)
GO_SRC := ./diskjockey-backend
GO_OUT := vendor/built

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
NFS_OUT := vendor/built
NFS_DRIVERS := ftp

vendor-gonetworkfs:
	@echo "\nBuilding go-networkfs drivers ($(NFS_DRIVERS))...\n"
	@SRCROOT=. \
		NFS_SRC="$(NFS_SRC)" \
		NFS_OUT="$(NFS_OUT)" \
		DRIVERS="$(NFS_DRIVERS)" \
		./scripts/build-gonetworkfs.sh

# Add specific driver (e.g., make vendor-gonetworkfs-add DRIVER=sftp)
vendor-gonetworkfs-add:
	@if [ -z "$(DRIVER)" ]; then \
		echo "Usage: make vendor-gonetworkfs-add DRIVER=sftp"; \
		exit 1; \
	fi
	@DRIVERS="$(NFS_DRIVERS) $(DRIVER)" $(MAKE) vendor-gonetworkfs

# Build all vendored dependencies
vendor-all: vendor-ext4rs vendor-gonetworkfs

clean-all: clean vendor-ext4rs-clean
	@rm -rf $(NFS_OUT)
