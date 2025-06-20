package main

import (
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/christhomas/diskjockey/diskjockey-backend/disktypes"
	"github.com/christhomas/diskjockey/diskjockey-backend/ipc"
	"github.com/christhomas/diskjockey/diskjockey-backend/services"
)

func main() {
	var configDir string
	flag.StringVar(&configDir, "config-dir", "", "Directory for config and DB files")
	flag.Parse()

	if configDir == "" {
		fmt.Println("No config dir specified, using default")
		configDir = "./config"
	}

	if _, err := os.Stat(configDir); os.IsNotExist(err) {
		fmt.Printf("Config dir does not exist, creating: %s\n", configDir)
		os.Exit(1)
	}

	fmt.Println("DiskJockey Backend starting...")

	fmt.Printf("Config Dir: %s\n", configDir)

	dbPath := filepath.Join(configDir, "diskjockey.sqlite")
	sqliteService := services.NewSQLiteService(dbPath)
	if err := sqliteService.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to open db: %v\n", err)
		os.Exit(1)
	}
	if err := sqliteService.Migrate(); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to migrate db: %v\n", err)
		os.Exit(1)
	}

	configService := services.NewConfigService(sqliteService)
	diskTypeService := services.NewDiskTypeService()
	diskTypeService.RegisterDiskType(disktypes.LocalDirectoryDiskType{})
	diskTypeService.RegisterDiskType(disktypes.FTPDiskType{})
	diskTypeService.RegisterDiskType(disktypes.SFTPDiskType{})
	diskTypeService.RegisterDiskType(disktypes.SMBDiskType{})
	diskTypeService.RegisterDiskType(disktypes.DropboxDiskType{})
	diskTypeService.RegisterDiskType(disktypes.WebDAVDiskType{})

	fmt.Println("Registered disk types:")
	for _, info := range diskTypeService.ListDiskTypes() {
		fmt.Printf("- %s: %s\n", info.Name, info.Description)
	}

	// Start backend server (listen for incoming connections)
	server := ipc.NewBackendServer(configService, diskTypeService)
	port, err := server.RunServer()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Backend server error: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("Listening on port %d\n", port)

	// Create a channel to wait for signals
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	// Block indefinitely until a signal is received
	fmt.Println("Server running. Press Ctrl+C to exit.")
	sig := <-sigChan // This will block until a signal is sent to the channel
	fmt.Printf("Received signal %v, shutting down...\n", sig)
}
