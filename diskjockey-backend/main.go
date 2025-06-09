package main

import (
	"flag"
	"fmt"
	"io/ioutil"
	"os"
	"path/filepath"

	"github.com/christhomas/diskjockey/diskjockey-backend/ipc"
	"github.com/christhomas/diskjockey/diskjockey-backend/plugins"
	"github.com/christhomas/diskjockey/diskjockey-backend/proto/api"
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
		fmt.Println("Config dir does not exist, creating")
		if err := os.MkdirAll(configDir, 0755); err != nil {
			fmt.Fprintf(os.Stderr, "Failed to create config dir: %v\n", err)
			os.Exit(1)
		}
	}

	// Connect to helper and perform CONNECT handshake
	helperAPI, err := ipc.NewHelperAPI(helperPort)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to connect to helper: %v\n", err)
		os.Exit(1)
	}
	defer helperAPI.Close()
	if err := helperAPI.Connect(api.ConnectRequest_BACKEND); err != nil {
		fmt.Fprintf(os.Stderr, "CONNECT with BACKEND role to helper failed: %v\n", err)
		os.Exit(1)
	}

	// FIXME: deprecated socketPath is no longer used
	socketPath := filepath.Join(configDir, "diskjockey.backend.sock")

	dbPath := filepath.Join(configDir, "diskjockey.sqlite")

	if err := ensureFileExists(dbPath, ""); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create db: %v\n", err)
		os.Exit(1)
	}

	configService := services.NewConfigService(services.NewSQLiteService(dbPath), socketPath)
	pluginService := services.NewPluginService()
	pluginService.RegisterPluginType(plugins.LocalDirectoryPlugin{})
	pluginService.RegisterPluginType(plugins.FTPPlugin{})
	pluginService.RegisterPluginType(plugins.SFTPPlugin{})
	pluginService.RegisterPluginType(plugins.SMBPlugin{})
	pluginService.RegisterPluginType(plugins.DropboxPlugin{})
	pluginService.RegisterPluginType(plugins.WebDAVPlugin{})

	server, err := ipc.NewServer(configService, pluginService)

	if err != nil {
		fmt.Printf("[Startup Error] %v\n", err)
		os.Exit(1)
	}

	if err := server.Start(); err != nil {
		fmt.Println("IPC server error:", err)
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
