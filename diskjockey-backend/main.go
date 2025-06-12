package main

import (
	"flag"
	"fmt"
	"io/ioutil"
	"os"
	"path/filepath"

	"github.com/christhomas/diskjockey/diskjockey-backend/ipc"
	"github.com/christhomas/diskjockey/diskjockey-backend/plugins"
	"github.com/christhomas/diskjockey/diskjockey-backend/services"
)

func main() {
	var configDir string
	var helperPort int

	flag.IntVar(&helperPort, "helper-port", 0, "Port to connect to DiskJockeyHelper")
	flag.StringVar(&configDir, "config-dir", "", "Directory for config and DB files")
	flag.Parse()

	if helperPort == 0 {
		fmt.Fprintln(os.Stderr, "--helper-port is required")
		os.Exit(1)
	}

	if configDir == "" {
		fmt.Println("No config dir specified, using default")
		configDir = "./config"
	}

	if _, err := os.Stat(configDir); os.IsNotExist(err) {
		fmt.Printf("Config dir does not exist, creating: %s\n", configDir)
		os.Exit(1)
	}

	fmt.Printf("DiskJockeyBackend starting... port='%d', configDir='%s'\n", helperPort, configDir)

	// FIXME: deprecated socketPath is no longer used
	socketPath := filepath.Join(configDir, "diskjockey.backend.sock")

	dbPath := filepath.Join(configDir, "diskjockey.sqlite")
	sqliteService := services.NewSQLiteService(dbPath)

	if err := ensureFileExists(dbPath, ""); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create db: %v\n", err)
		os.Exit(1)
	} else {
		fmt.Printf("Found db: %s\n", dbPath)
	}

	configService := services.NewConfigService(sqliteService, socketPath)
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

	// Create a new backend client
	client := ipc.NewBackendClient(configService, pluginService)

	// Connect to main app (combined app+helper) and process messages
	if err := client.RunClient(helperPort); err != nil {
		fmt.Fprintf(os.Stderr, "Backend client error: %v\n", err)
		os.Exit(1)
	}
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
