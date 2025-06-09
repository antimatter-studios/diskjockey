package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"os"

	"github.com/christhomas/diskjockey/diskjockey-backend/proto/api"
	"google.golang.org/protobuf/proto"
)

// debugMode is set in main.go
func lsCommand(args []string) {
	if len(args) < 1 {
		fmt.Println("Usage: djctl ls <mount> [path]")
		os.Exit(1)
	}
	mount := args[0]
	path := "/"
	if len(args) > 1 {
		path = args[1]
	}
	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		fmt.Println("Failed to connect to daemon:", err)
		os.Exit(1)
	}
	defer conn.Close()
	// Build ListDirRequest
	// Query backend for mount list to resolve mount name to mount_id
	mountsReq := &api.ListMountsRequest{}
	mountsMsg, err := proto.Marshal(mountsReq)
	if err != nil {
		fmt.Println("Marshal ListMountsRequest error:", err)
		os.Exit(1)
	}
	var lenBuf [4]byte
	var respType [1]byte
	// --- ListMountsRequest ---
	binary.BigEndian.PutUint32(lenBuf[:], uint32(len(mountsMsg)+1))
	if _, err := conn.Write(lenBuf[:]); err != nil {
		fmt.Println("Write len error:", err)
		os.Exit(1)
	}
	if _, err := conn.Write([]byte{byte(api.MessageType_LIST_MOUNTS_REQUEST)}); err != nil {
		fmt.Println("Write type error:", err)
		os.Exit(1)
	}
	if _, err := conn.Write(mountsMsg); err != nil {
		fmt.Println("Write msg error:", err)
		os.Exit(1)
	}
	// Read ListMountsResponse
	if _, err := conn.Read(lenBuf[:]); err != nil {
		fmt.Println("Read resp len error:", err)
		os.Exit(1)
	}
	respLen := binary.BigEndian.Uint32(lenBuf[:])
	if respLen < 1 {
		fmt.Println("Invalid resp len")
		os.Exit(1)
	}
	if _, err := conn.Read(respType[:]); err != nil {
		fmt.Println("Read resp type error:", err)
		os.Exit(1)
	}
	if respType[0] != byte(api.MessageType_LIST_MOUNTS_REQUEST) {
		fmt.Println("Unexpected resp type for ListMountsResponse:", respType[0])
		os.Exit(1)
	}
	respBytes := make([]byte, respLen-1)
	if _, err := io.ReadFull(conn, respBytes); err != nil {
		fmt.Println("Read resp bytes error:", err)
		os.Exit(1)
	}
	mountsResp := &api.ListMountsResponse{}
	if err := proto.Unmarshal(respBytes, mountsResp); err != nil {
		fmt.Println("Unmarshal ListMountsResponse error:", err)
		os.Exit(1)
	}
	if mountsResp.Error != "" {
		fmt.Println("Server error (mounts):", mountsResp.Error)
		os.Exit(1)
	}
	var mountID uint32
	found := false
	for _, m := range mountsResp.Mounts {
		if m.Name == mount {
			mountID = m.MountId
			found = true
			break
		}
	}
	if !found {
		fmt.Printf("Mount '%s' not found\n", mount)
		os.Exit(1)
	}
	// --- ListDirRequest ---
	req := &api.ListDirRequest{
		MountId: mountID,
		Path:   path,
	}
	msg, err := proto.Marshal(req)
	if err != nil {
		fmt.Println("Marshal error:", err)
		os.Exit(1)
	}
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
	respLen = binary.BigEndian.Uint32(lenBuf[:])
	if respLen < 1 {
		fmt.Println("Invalid resp len")
		os.Exit(1)
	}
	if _, err := conn.Read(respType[:]); err != nil {
		fmt.Println("Read resp type error:", err)
		os.Exit(1)
	}
	if respType[0] != 1 {
		fmt.Println("Unexpected resp type for ListDirResponse:", respType[0])
		os.Exit(1)
	}
	respBytes = make([]byte, respLen-1)
	if _, err := io.ReadFull(conn, respBytes); err != nil {
		fmt.Println("Read resp bytes error:", err)
		os.Exit(1)
	}
	resp := &api.ListDirResponse{}
	if err := proto.Unmarshal(respBytes, resp); err != nil {
		fmt.Println("Unmarshal error:", err)
		os.Exit(1)
	}
	if resp.Error != "" {
		fmt.Println("Server error:", resp.Error)
		os.Exit(1)
	}
	for _, f := range resp.Files {
		kind := "file"
		if f.IsDir {
			kind = "dir"
		}
		fmt.Printf("%s\t%s\t%d\n", kind, f.Name, f.Size)
	}
}
