package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"

	"google.golang.org/protobuf/proto"
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
func sendRequestAndGetResponse(req proto.Message, reqType, respTypeExpected byte) ([]byte, error) {
	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		return nil, fmt.Errorf("Failed to connect to daemon: %w", err)
	}
	defer conn.Close()
	msg, err := proto.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("Marshal error: %w", err)
	}
	var lenBuf [4]byte
	binary.BigEndian.PutUint32(lenBuf[:], uint32(len(msg)+1))
	if _, err := conn.Write(lenBuf[:]); err != nil {
		return nil, fmt.Errorf("Write len error: %w", err)
	}
	if _, err := conn.Write([]byte{reqType}); err != nil {
		return nil, fmt.Errorf("Write type error: %w", err)
	}
	if _, err := conn.Write(msg); err != nil {
		return nil, fmt.Errorf("Write msg error: %w", err)
	}
	if _, err := conn.Read(lenBuf[:]); err != nil {
		return nil, fmt.Errorf("Read resp len error: %w", err)
	}
	respLen := binary.BigEndian.Uint32(lenBuf[:])
	if respLen < 1 {
		return nil, fmt.Errorf("Invalid resp len")
	}
	var respType [1]byte
	if _, err := conn.Read(respType[:]); err != nil {
		return nil, fmt.Errorf("Read resp type error: %w", err)
	}
	if respType[0] != respTypeExpected {
		return nil, fmt.Errorf("Unexpected resp type: got %d, want %d", respType[0], respTypeExpected)
	}
	respBytes := make([]byte, respLen-1)
	if _, err := io.ReadFull(conn, respBytes); err != nil {
		return nil, fmt.Errorf("Read resp bytes error: %w", err)
	}
	return respBytes, nil
}

func cpUpload(mount string, localPath string, remotePath string) {
	// ... implementation ...
}

func cpDownload(mount string, remotePath string, localPath string) {
	// ... implementation ...
}

func cpCommand(args []string) {
	// ... implementation ...
}
