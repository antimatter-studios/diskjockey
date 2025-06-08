package main

import (
	"fmt"
	"os"

	"github.com/christhomas/diskjockey/diskjockey-backend/ipc"
	"github.com/christhomas/diskjockey/diskjockey-backend/plugins"
	"github.com/christhomas/diskjockey/diskjockey-backend/services"
)

func main() {
	fmt.Println("Go backend daemon starting up")

	// Get config path from --config flag
	configPath := "server.json"
	for i, arg := range os.Args {
		if arg == "--config" && i+1 < len(os.Args) {
			configPath = os.Args[i+1]
		}
	}

	configService, err := services.NewConfigService(configPath)
	if err != nil {
		fmt.Printf("[Startup Error] failed to load config: %v\n", err)
		os.Exit(1)
	}

	pluginService := services.NewPluginService(configService)
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
