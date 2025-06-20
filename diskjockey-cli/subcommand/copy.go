package subcommand

import (
	"github.com/christhomas/diskjockey/diskjockey-cli/ipc"
)

// Protocol message type values for socket framing (not part of protobuf spec).
// These must match the server/daemon framing logic.
//
// Socket protocol message type IDs:
//
//	2: ReadFileRequest / ReadFileResponse (see protocol_definitions.proto)
//	3: WriteFileRequest / WriteFileResponse (see protocol_definitions.proto)
const (
	typeReadFileRequest   = 2 // vfs.ReadFileRequest
	typeReadFileResponse  = 2 // vfs.ReadFileResponse
	typeWriteFileRequest  = 3 // vfs.WriteFileRequest
	typeWriteFileResponse = 3 // vfs.WriteFileResponse
)

// cpCommand implements: djctl cp <mount> <remote_path> <local_path>
// Use protoipc.SendMessage/ReceiveMessage for protobuf-based socket communication.

func CopyUpload(mount string, localPath string, remotePath string) {
	// ... implementation ...
}

func CopyDownload(mount string, remotePath string, localPath string) {
	// ... implementation ...
}

func CopyCommand(client *ipc.Client, args []string) {
	// ... implementation ...
}
