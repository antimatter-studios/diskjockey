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
# Source of truth: github.com/christhomas/ext4-rust
# For local iteration, build from a sibling checkout via EXT4RS_SRC.
EXT4RS_SRC ?= /Volumes/sdcard256gb/projects/ext4-rust
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

# Build ext4rs from the sibling checkout and stage it under vendor/ext4rs/.
# Xcode's DiskJockeyEXT4 target links vendor/ext4rs/libext4rs.a and imports
# vendor/ext4rs/ext4rs.h via its bridging header.
vendor-ext4rs:
	@echo "\nBuilding ext4rs from $(EXT4RS_SRC)...\n"
	@test -d "$(EXT4RS_SRC)" || (echo "EXT4RS_SRC=$(EXT4RS_SRC) does not exist. Clone github.com/christhomas/ext4-rust or override EXT4RS_SRC." >&2; exit 1)
	cd "$(EXT4RS_SRC)" && ./build.sh
	mkdir -p $(EXT4RS_VENDOR)/include
	cp "$(EXT4RS_SRC)/dist/libext4rs.a"    $(EXT4RS_VENDOR)/libext4rs.a
	cp "$(EXT4RS_SRC)/dist/ext4rs.h"       $(EXT4RS_VENDOR)/include/ext4rs.h
	cp -R "$(EXT4RS_SRC)/dist/ext4rs.xcframework" $(EXT4RS_VENDOR)/ext4rs.xcframework
	@echo "ext4rs vendored into $(EXT4RS_VENDOR)/"
	@lipo -info $(EXT4RS_VENDOR)/libext4rs.a

vendor-ext4rs-clean:
	rm -rf $(EXT4RS_VENDOR)
