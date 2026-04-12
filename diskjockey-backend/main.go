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

// resolveAppGroupDir returns the macOS app group container path for the given group ID.
// On macOS this is ~/Library/Group Containers/<group-id>/
func resolveAppGroupDir(groupID string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	dir := filepath.Join(home, "Library", "Group Containers", groupID)
	if info, err := os.Stat(dir); err == nil && info.IsDir() {
		return dir
	}
	return ""
}

func main() {
	var configDir string
	var portFile string
	var noTimeout bool
	flag.StringVar(&configDir, "config-dir", "", "Directory for config and DB files")
	flag.StringVar(&portFile, "port-file", "", "Write listening port to this file (for service discovery)")
	flag.BoolVar(&noTimeout, "no-timeout", false, "Disable inactivity timeout (for background service mode)")
	flag.Parse()

	// Resolve defaults using the macOS app group container
	appGroupDir := resolveAppGroupDir("group.com.antimatterstudios.diskjockey")

	if configDir == "" {
		if appGroupDir != "" {
			configDir = filepath.Join(appGroupDir, "config")
		} else {
			configDir = "./config"
		}
		fmt.Printf("No config dir specified, using default: %s\n", configDir)
	}

	if portFile == "" && appGroupDir != "" {
		portFile = filepath.Join(appGroupDir, "backend.port")
		fmt.Printf("No port file specified, using default: %s\n", portFile)
	}

	if _, err := os.Stat(configDir); os.IsNotExist(err) {
		fmt.Printf("Config dir does not exist, creating: %s\n", configDir)
		if err := os.MkdirAll(configDir, 0755); err != nil {
			fmt.Fprintf(os.Stderr, "Failed to create config dir: %v\n", err)
			os.Exit(1)
		}
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

	mountService := services.NewMountService(configService, diskTypeService)

	// Start backend server (listen for incoming connections)
	server := ipc.NewBackendServer(configService, diskTypeService, mountService)
	port, err := server.RunServer(!noTimeout)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Backend server error: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("Listening on port %d\n", port)

	// Write port file for service discovery
	if portFile != "" {
		if err := os.WriteFile(portFile, []byte(fmt.Sprintf("%d", port)), 0644); err != nil {
			fmt.Fprintf(os.Stderr, "Failed to write port file: %v\n", err)
		}
	}

	// Create a channel to wait for signals
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	// Block until either a signal is received or server shuts itself down (inactivity)
	fmt.Println("Server running. Press Ctrl+C to exit.")
	select {
	case sig := <-sigChan:
		fmt.Printf("Received signal %v, shutting down...\n", sig)
	case <-server.Done():
		fmt.Println("Server stopped, cleaning up...")
	}

	// Graceful cleanup
	if portFile != "" {
		os.Remove(portFile)
	}
	if err := server.Shutdown(); err != nil {
		fmt.Fprintf(os.Stderr, "Server shutdown error: %v\n", err)
	}
	if err := sqliteService.Stop(); err != nil {
		fmt.Fprintf(os.Stderr, "Database close error: %v\n", err)
	}
	fmt.Println("Shutdown complete.")
}
