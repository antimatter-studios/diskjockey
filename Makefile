DISKJOCKEY_BACKEND := diskjockey-backend
DISKJOCKEY_BACKEND_BINARY := diskjockey-backend
DISKJOCKEY_CLI := diskjockey-cli
DISKJOCKEY_CLI_BINARY := djctl
DISKJOCKEY_LIB := DiskJockeyLibrary
FILEPROVIDER_PROTOCOL := fileprovider
BACKEND_PROTOCOL := backend
FILEPROVIDER_PROTO_SRC=${DISKJOCKEY_LIB}/Protobuf/${FILEPROVIDER_PROTOCOL}.proto
BACKEND_PROTO_SRC=${DISKJOCKEY_BACKEND}/proto/${BACKEND_PROTOCOL}.proto


.PHONY: all proto djb djctl clean

all: proto djb djctl

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

clean:
	@echo "\nCleaning up...\n"
	rm -f ./${DISKJOCKEY_LIB}/Protobuf/${BACKEND_PROTOCOL}.pb.swift
	rm -f ./${DISKJOCKEY_LIB}/Protobuf/${FILEPROVIDER_PROTOCOL}.pb.swift
	rm -f ./${DISKJOCKEY_BACKEND}/proto/${BACKEND_PROTOCOL}.pb.go
	rm -f ./${DISKJOCKEY_BACKEND}/${DISKJOCKEY_BACKEND_BINARY}
	rm -f ./${DISKJOCKEY_CLI}/${DISKJOCKEY_CLI_BINARY}
