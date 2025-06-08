package ipc

import (
	"fmt"
	"net"
	"os"

	"diskjockey-backend/config"
	"diskjockey-backend/plugins"
)

// Server encapsulates the backend server state and logic.
type Server struct {
	Registry   *plugins.PluginRegistry
	ConfigSvc  *config.ConfigService
	SocketPath string
}

// NewServer initializes the server, plugins, and mounts.
func NewServer(configPath, socketPath string) (*Server, error) {
	configSvc, err := config.NewConfigService(configPath)
	if err != nil {
		return nil, err
	}
	reg := plugins.NewRegistry(configSvc)
	reg.RegisterPluginType(plugins.LocalDirectoryPlugin{})
	reg.RegisterPluginType(plugins.FTPPlugin{})
	reg.RegisterPluginType(plugins.SFTPPlugin{})
	reg.RegisterPluginType(plugins.SMBPlugin{})
	reg.RegisterPluginType(plugins.DropboxPlugin{})
	reg.RegisterPluginType(plugins.WebDAVPlugin{})
	for _, m := range configSvc.ListMountpoints() {
		if err := reg.AddMount(m.Name, m.Type, m.Config); err != nil {
			fmt.Printf("[Mount Error] Failed to add mount '%s': %v\n", m.Name, err)
		}
	}
	return &Server{Registry: reg, ConfigSvc: configSvc, SocketPath: socketPath}, nil
}

// Start runs the IPC server and blocks until exit.
func (s *Server) Start() error {
	fmt.Println("Registered plugins:")
	for name, enabled := range s.Registry.ListPluginTypes() {
		fmt.Printf("- %s (enabled: %v)\n", name, enabled)
	}
	fmt.Println("Starting IPC server on", s.SocketPath)

	if err := os.RemoveAll(s.SocketPath); err != nil {
		return err
	}
	ln, err := net.Listen("unix", s.SocketPath)
	if err != nil {
		return err
	}
	defer ln.Close()
	fmt.Println("IPC server listening on", s.SocketPath)
	for {
		conn, err := ln.Accept()
		if err != nil {
			fmt.Println("accept error:", err)
			continue
		}
		go s.handleConn(conn)
	}
}

// GracefulShutdown performs cleanup before exit. Call this from anywhere.
func (s *Server) GracefulShutdown() {
	fmt.Println("[RDM] (stub) GracefulShutdown: cancel transfers, persist queue, close connections")
	// TODO: Implement transfer cancellation, queue persistence, and connection closing.
}
