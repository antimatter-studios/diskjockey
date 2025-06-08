module github.com/christhomas/diskjockey/diskjockey-cli

go 1.24.3

require (
	github.com/christhomas/diskjockey/diskjockey-backend v0.0.0
	google.golang.org/protobuf v1.36.6
)

replace github.com/christhomas/diskjockey/diskjockey-backend => ../diskjockey-backend
