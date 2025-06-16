package ipc

import (
	"fmt"
	"net"
	"os"
	"time"

	"github.com/christhomas/diskjockey/diskjockey-backend/proto/api"
	"github.com/christhomas/diskjockey/diskjockey-backend/services"
)

type BackendServer struct {
	configService *services.ConfigService
	pluginService *services.PluginService
	shutdownChan chan struct{}  // Channel to signal shutdown
	listener     net.Listener   // Store the listener for graceful shutdown
}

func NewBackendServer(config *services.ConfigService, plugins *services.PluginService) *BackendServer {
	return &BackendServer{
		configService: config,
		pluginService: plugins,
		shutdownChan: make(chan struct{}),
	}
}

// RunServer starts the backend server and returns the port it's listening on.
// This function starts a goroutine that accepts connections indefinitely.
func (s *BackendServer) RunServer() (int, error) {
	var err error
	s.listener, err = net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, fmt.Errorf("failed to listen: %w", err)
	}

	addr := s.listener.Addr().(*net.TCPAddr)
	port := addr.Port
	// Write directly to stdout with a newline and flush
	fmt.Printf("PORT=%d\n", port)
	// Ensure the output is flushed immediately
	os.Stdout.Sync()
	// Add a small delay to ensure the output is processed
	time.Sleep(100 * time.Millisecond)

	// Start accepting connections in a goroutine
	go func() {
		fmt.Println("Server started, accepting connections...")
		for {
			conn, err := s.listener.Accept()
			if err != nil {
				// Check if the error is due to the listener being closed
				select {
				case <-s.shutdownChan:
					// Normal shutdown, exit the loop
					return
				default:
					// Unexpected error
					fmt.Fprintf(os.Stderr, "accept error: %v\n", err)
			}
			continue
		}
		go s.handleConnection(conn)
	}
}()

	return port, nil
}

// Shutdown gracefully shuts down the server
func (s *BackendServer) Shutdown() error {
	close(s.shutdownChan) // Signal all goroutines to stop
	if s.listener != nil {
		return s.listener.Close()
	}
	return nil
}

// handleConnection processes a single client connection
func (s *BackendServer) handleConnection(conn net.Conn) {
	defer conn.Close()
	// Read message type and payload (same as client)
	var buf [4]byte
	if _, err := conn.Read(buf[:]); err != nil {
		fmt.Fprintf(os.Stderr, "failed to read message length: %v\n", err)
		return
	}
	msgLen := int(buf[0])<<24 | int(buf[1])<<16 | int(buf[2])<<8 | int(buf[3])
	msgType := make([]byte, 1)
	if _, err := conn.Read(msgType); err != nil {
		fmt.Fprintf(os.Stderr, "failed to read message type: %v\n", err)
		return
	}
	payload := make([]byte, msgLen-1)
	if _, err := conn.Read(payload); err != nil {
		fmt.Fprintf(os.Stderr, "failed to read message payload: %v\n", err)
		return
	}
	// Handle message (reuse client logic)
	client := NewBackendClient(s, s.configService, s.pluginService)
	if err := client.handleMessage(api.MessageType(msgType[0]), payload, conn); err != nil {
		fmt.Fprintf(os.Stderr, "handleMessage error: %v\n", err)
	}
}
