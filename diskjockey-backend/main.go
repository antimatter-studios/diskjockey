package main

import (
	"flag"
	"fmt"
	"io/ioutil"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/christhomas/diskjockey/diskjockey-backend/ipc"
	"github.com/christhomas/diskjockey/diskjockey-backend/plugins"
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

	if err := ensureFileExists(dbPath, ""); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create db: %v\n", err)
		os.Exit(1)
	} else {
		fmt.Printf("Found db: %s\n", dbPath)
	}

	configService := services.NewConfigService(sqliteService)
	pluginService := services.NewPluginService()
	pluginService.RegisterPluginType(plugins.LocalDirectoryPlugin{})
	pluginService.RegisterPluginType(plugins.FTPPlugin{})
	pluginService.RegisterPluginType(plugins.SFTPPlugin{})
	pluginService.RegisterPluginType(plugins.SMBPlugin{})
	pluginService.RegisterPluginType(plugins.DropboxPlugin{})
	pluginService.RegisterPluginType(plugins.WebDAVPlugin{})

	fmt.Println("Registered plugins:")
	for _, info := range pluginService.ListPluginTypes() {
		fmt.Printf("- %s: %s\n", info.Name, info.Description)
	}

	// Start backend server (listen for incoming connections)
	server := ipc.NewBackendServer(configService, pluginService)
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

// ensureFileExists creates the file at path with defaultContent if it does not exist.
func ensureFileExists(path, defaultContent string) error {
	if _, err := os.Stat(path); os.IsNotExist(err) {
		dir := filepath.Dir(path)
		if err := os.MkdirAll(dir, 0755); err != nil {
			return err
		}
		return ioutil.WriteFile(path, []byte(defaultContent), 0644)
	}
	return nil
}
