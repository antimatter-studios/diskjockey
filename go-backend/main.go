package main

//go:generate protoc --go_out=paths=source_relative:./ ./shared/protocol_definitions.proto

import (
	"disk-jockey/go-backend/config"
	"disk-jockey/go-backend/ipc"
	"disk-jockey/go-backend/plugins"
	"fmt"
	"os"
)

func main() {
	fmt.Println("Go backend daemon starting up")

	// Load configuration from server.json

	// Create the config service
	configSvc, err := config.NewConfigService("server.json")
	if err != nil {
		fmt.Printf("[Config Error] Failed to load config service: %v\n", err)
		os.Exit(1)
	}
	reg := plugins.NewRegistry(configSvc)
	// Register available plugin types
	reg.RegisterPluginType(plugins.LocalDirectoryPlugin{})
	reg.RegisterPluginType(plugins.FTPPlugin{})
	reg.RegisterPluginType(plugins.SFTPPlugin{})
	reg.RegisterPluginType(plugins.SMBPlugin{})
	reg.RegisterPluginType(plugins.DropboxPlugin{})
	reg.RegisterPluginType(plugins.WebDAVPlugin{})

	// Add mounts from config
	for _, m := range configSvc.ListMountpoints() {
		if err := reg.AddMount(m.Name, m.Type, m.Config); err != nil {
			fmt.Printf("[Mount Error] Failed to add mount '%s': %v\n", m.Name, err)
			continue
		}
	}

	fmt.Println("Registered plugins:")
	for name, enabled := range reg.ListPluginTypes() {
		fmt.Printf("- %s (enabled: %v)\n", name, enabled)
	}

	// Start IPC server
	socketPath := "/tmp/diskjockey.sock"
	fmt.Println("Starting IPC server on", socketPath)

	if err := ipc.StartServer(socketPath, reg); err != nil {
		fmt.Println("IPC server error:", err)
		os.Exit(1)
	}
}
