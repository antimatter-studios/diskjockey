DISKJOCKEY_BACKEND := diskjockey-backend
DISKJOCKEY_BACKEND_BINARY := diskjockey-backend
DISKJOCKEY_CLI := diskjockey-cli
DISKJOCKEY_CLI_BINARY := djctl
SWIFT_PB_OUTPUT := DiskJockeyLibrary
PROTO_SRC=${DISKJOCKEY_BACKEND}/proto/protocol_definitions.proto

.PHONY: all proto djb djctl clean

all: proto djb djctl

proto:
	@echo "\nGenerating protocol definitions...\n"
	protoc -I=${DISKJOCKEY_BACKEND}/proto --swift_opt=Visibility=Public --swift_out=${SWIFT_PB_OUTPUT}/ $(PROTO_SRC)
	protoc --go_out=./ $(PROTO_SRC)

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

clean:
	@echo "\nCleaning up...\n"
	rm -f ./${SWIFT_PB_OUTPUT}/protocol_definitions.pb.swift
	rm -f ./${DISKJOCKEY_BACKEND}/proto/api/protocol_definitions.pb.go
	rm -f ./${DISKJOCKEY_BACKEND}/${DISKJOCKEY_BACKEND_BINARY}
	rm -f ./${DISKJOCKEY_CLI}/${DISKJOCKEY_CLI_BINARY}
