package main

import (
	vfs "disk-jockey/go-backend/shared"
	"encoding/binary"
	"fmt"
	"net"
	"os"

	"google.golang.org/protobuf/proto"
)

func main() {
	socketPath := "/tmp/diskjockey.sock"
	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		fmt.Println("Failed to connect to daemon:", err)
		os.Exit(1)
	}
	defer conn.Close()

	// Send a ListDirRequest for the dummy plugin
	req := &vfs.ListDirRequest{
		Plugin: "dummy",
		Path:   "/",
	}
	msg, err := proto.Marshal(req)
	if err != nil {
		fmt.Println("Marshal error:", err)
		os.Exit(1)
	}
	var lenBuf [4]byte
	binary.BigEndian.PutUint32(lenBuf[:], uint32(len(msg)+1))
	if _, err := conn.Write(lenBuf[:]); err != nil {
		fmt.Println("Write len error:", err)
		os.Exit(1)
	}
	if _, err := conn.Write([]byte{1}); err != nil {
		fmt.Println("Write type error:", err)
		os.Exit(1)
	}
	if _, err := conn.Write(msg); err != nil {
		fmt.Println("Write msg error:", err)
		os.Exit(1)
	}

	// Read response
	if _, err := conn.Read(lenBuf[:]); err != nil {
		fmt.Println("Read resp len error:", err)
		os.Exit(1)
	}
	respLen := binary.BigEndian.Uint32(lenBuf[:])
	if respLen < 1 {
		fmt.Println("Invalid resp len")
		os.Exit(1)
	}
	var respType [1]byte
	if _, err := conn.Read(respType[:]); err != nil {
		fmt.Println("Read resp type error:", err)
		os.Exit(1)
	}
	respBytes := make([]byte, respLen-1)
	if _, err := conn.Read(respBytes); err != nil {
		fmt.Println("Read resp error:", err)
		os.Exit(1)
	}
	var resp vfs.ListDirResponse
	if respType[0] != 1 {
		fmt.Println("Unexpected resp type for ListDirResponse:", respType[0])
		os.Exit(1)
	}
	if err := proto.Unmarshal(respBytes, &resp); err != nil {
		fmt.Println("Unmarshal resp error:", err)
		os.Exit(1)
	}
	fmt.Printf("ListDirResponse: error=%v, files=\n", resp.Error)
	for _, f := range resp.Files {
		fmt.Printf("  - %s (size=%d, dir=%v)\n", f.Name, f.Size, f.IsDir)
	}

	// Now send a ReadFileRequest for dummy.txt
	readReq := &vfs.ReadFileRequest{
		Plugin: "dummy",
		Path:   "dummy.txt",
	}
	readMsg, err := proto.Marshal(readReq)
	if err != nil {
		fmt.Println("Marshal ReadFileRequest error:", err)
		os.Exit(1)
	}
	binary.BigEndian.PutUint32(lenBuf[:], uint32(len(readMsg)+1))
	if _, err := conn.Write(lenBuf[:]); err != nil {
		fmt.Println("Write ReadFileRequest len error:", err)
		os.Exit(1)
	}
	if _, err := conn.Write([]byte{2}); err != nil {
		fmt.Println("Write ReadFileRequest type error:", err)
		os.Exit(1)
	}
	if _, err := conn.Write(readMsg); err != nil {
		fmt.Println("Write ReadFileRequest msg error:", err)
		os.Exit(1)
	}
	// Read ReadFileResponse
	if _, err := conn.Read(lenBuf[:]); err != nil {
		fmt.Println("Read ReadFileResponse len error:", err)
		os.Exit(1)
	}
	readRespLen := binary.BigEndian.Uint32(lenBuf[:])
	if readRespLen < 1 {
		fmt.Println("Invalid ReadFileResponse len")
		os.Exit(1)
	}
	var readRespType [1]byte
	if _, err := conn.Read(readRespType[:]); err != nil {
		fmt.Println("Read ReadFileResponse type error:", err)
		os.Exit(1)
	}
	readRespBytes := make([]byte, readRespLen-1)
	if _, err := conn.Read(readRespBytes); err != nil {
		fmt.Println("Read ReadFileResponse error:", err)
		os.Exit(1)
	}
	var readResp vfs.ReadFileResponse
	if readRespType[0] != 2 {
		fmt.Println("Unexpected resp type for ReadFileResponse:", readRespType[0])
		os.Exit(1)
	}
	if err := proto.Unmarshal(readRespBytes, &readResp); err != nil {
		fmt.Println("Unmarshal ReadFileResponse error:", err)
		os.Exit(1)
	}
	fmt.Printf("ReadFileResponse: error=%v, data=\"%s\"\n", readResp.Error, string(readResp.Data))
}
