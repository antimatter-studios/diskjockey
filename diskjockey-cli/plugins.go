package main

import (
	"encoding/binary"
	"fmt"
	"net"
	"os"

	"github.com/christhomas/diskjockey/diskjockey-backend/proto/api"
	"google.golang.org/protobuf/proto"
)

func listPlugins() {
	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		fmt.Println("Failed to connect to daemon:", err)
		os.Exit(1)
	}
	defer conn.Close()
	// Build request
	req := &api.ListPluginsRequest{}
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
	if _, err := conn.Write([]byte{10}); err != nil {
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
	if respType[0] != 10 {
		fmt.Println("Unexpected resp type for ListPluginsResponse:", respType[0])
		os.Exit(1)
	}
	respBytes := make([]byte, respLen-1)
	if _, err := conn.Read(respBytes); err != nil {
		fmt.Println("Read resp bytes error:", err)
		os.Exit(1)
	}
	resp := &api.ListPluginsResponse{}
	if err := proto.Unmarshal(respBytes, resp); err != nil {
		fmt.Println("Unmarshal error:", err)
		os.Exit(1)
	}
	if resp.Error != "" {
		fmt.Println("Server error:", resp.Error)
		os.Exit(1)
	}
	for _, p := range resp.Plugins {
		fmt.Printf("Plugin: %s\n  Description: %s\n", p.Name, p.Description)
		for _, f := range p.ConfigFields {
			fmt.Printf("    - %s (%s) required=%v: %s\n", f.Name, f.Type, f.Required, f.Description)
		}
	}
}
