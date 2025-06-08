package main

import (
	"fmt"
	"os"

	"diskjockey-backend/ipc"
)

func main() {
	fmt.Println("Go backend daemon starting up")
	server, err := ipc.NewServer("server.json", "/tmp/diskjockey.rdm.sock")
	if err != nil {
		fmt.Printf("[Startup Error] %v\n", err)
		os.Exit(1)
	}
	if err := server.Start(); err != nil {
		fmt.Println("IPC server error:", err)
		os.Exit(1)
	}
}
