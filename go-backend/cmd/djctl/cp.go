package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"os"

	vfs "disk-jockey/go-backend/shared"

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
	// Upload: cp <mount> <local_path> <remote_path>
	data, err := os.ReadFile(localPath)
	if err != nil {
		fmt.Println("Failed to read local file:", err)
		os.Exit(1)
	}
	req := &vfs.WriteFileRequest{
		Plugin: mount,
		Path:   remotePath,
		Data:   data,
	}
	respBytes, err := sendRequestAndGetResponse(req, typeWriteFileRequest, typeWriteFileResponse)
	if err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
	resp := &vfs.WriteFileResponse{}
	if err := proto.Unmarshal(respBytes, resp); err != nil {
		fmt.Println("Unmarshal error:", err)
		os.Exit(1)
	}
	if resp.Error != "" {
		fmt.Println("Remote write error:", resp.Error)
		os.Exit(1)
	}
	fmt.Printf("Copied %s to %s:%s\n", localPath, mount, remotePath)
}

func cpDownload(mount string, remotePath string, localPath string) {
	// Download: cp <mount> <remote_path> <local_path>
	req := &vfs.ReadFileRequest{
		Plugin: mount,
		Path:   remotePath,
	}
	respBytes, err := sendRequestAndGetResponse(req, typeReadFileRequest, typeReadFileResponse)
	if err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
	resp := &vfs.ReadFileResponse{}
	if err := proto.Unmarshal(respBytes, resp); err != nil {
		fmt.Println("Unmarshal error:", err)
		os.Exit(1)
	}
	if resp.Error != "" {
		fmt.Println("Remote read error:", resp.Error)
		os.Exit(1)
	}
	if err := os.WriteFile(localPath, resp.Data, 0644); err != nil {
		fmt.Println("Failed to write local file:", err)
		os.Exit(1)
	}
	fmt.Printf("Copied %s:%s to %s\n", mount, remotePath, localPath)
}

func cpCommand(args []string) {
	if len(args) != 3 {
		fmt.Println("Usage: djctl cp <mount> <remote_path> <local_path>  (download)\n   or: djctl cp <mount> <local_path> <remote_path> (upload)")
		os.Exit(1)
	}
	mount := args[0]
	arg1 := args[1]
	arg2 := args[2]

	if fi, err := os.Stat(arg1); err == nil && !fi.IsDir() {
		cpUpload(mount, arg1, arg2)
	} else {
		cpDownload(mount, arg1, arg2)
	}
}
