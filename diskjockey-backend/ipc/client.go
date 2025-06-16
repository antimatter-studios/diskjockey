package ipc

import (
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"time"

	"github.com/christhomas/diskjockey/diskjockey-backend/proto/api"
	"github.com/christhomas/diskjockey/diskjockey-backend/services"
	"google.golang.org/protobuf/proto"
)

type BackendClient struct {
	configService *services.ConfigService
	pluginService *services.PluginService
	server        *BackendServer // Reference to the server for shutdown
	handshakeDone bool
}

func NewBackendClient(server *BackendServer, config *services.ConfigService, plugins *services.PluginService) *BackendClient {
	return &BackendClient{
		server:        server,
		configService: config,
		pluginService: plugins,
	}
}

// SendMessage sends a protobuf message with the specified message type over the connection.
func (c *BackendClient) SendMessage(conn net.Conn, msgType api.MessageType, pb proto.Message) error {
	payload, err := proto.Marshal(pb)
	if err != nil {
		return fmt.Errorf("failed to marshal message: %w", err)
	}
	var buf [4]byte
	binary.BigEndian.PutUint32(buf[:], uint32(len(payload)+1))
	if _, err := conn.Write(buf[:]); err != nil {
		return fmt.Errorf("failed to write message length: %w", err)
	}
	if _, err := conn.Write([]byte{byte(msgType)}); err != nil {
		return fmt.Errorf("failed to write message type: %w", err)
	}
	if _, err := conn.Write(payload); err != nil {
		return fmt.Errorf("failed to write message payload: %w", err)
	}
	return nil
}

// ReceiveMessage reads a message from the connection, returning the type and payload.
func (c *BackendClient) ReceiveMessage(conn net.Conn) (api.MessageType, []byte, error) {
	var buf [4]byte
	if _, err := conn.Read(buf[:]); err != nil {
		return 0, nil, fmt.Errorf("failed to read message length: %w", err)
	}
	msgLen := binary.BigEndian.Uint32(buf[:])
	msgType := make([]byte, 1)
	if _, err := conn.Read(msgType); err != nil {
		return 0, nil, fmt.Errorf("failed to read message type: %w", err)
	}
	payload := make([]byte, msgLen-1)
	if _, err := conn.Read(payload); err != nil {
		return 0, nil, fmt.Errorf("failed to read message payload: %w", err)
	}
	return api.MessageType(msgType[0]), payload, nil
}

// RunClient connects to the main app on the given port, sends CONNECT, and processes messages in a loop.
func (c *BackendClient) RunClient(port int) error {
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		return fmt.Errorf("failed to connect to main app: %w", err)
	}
	defer conn.Close()

	// Send CONNECT message using generic SendMessage
	connectMsg := &api.ConnectRequest{Role: api.ConnectRequest_BACKEND}
	if err := c.SendMessage(conn, api.MessageType_CONNECT, connectMsg); err != nil {
		return fmt.Errorf("failed to send CONNECT: %w", err)
	}
	fmt.Printf("[BackendClient] CONNECT sent to address '%s', entering message loop...\n", addr)

	c.handshakeDone = false

	// Main message loop
	for {
		msgType, msg, err := c.ReceiveMessage(conn)
		if err != nil {
			fmt.Fprintf(os.Stderr, "[BackendClient] receive message error: %v\n", err)
			return err
		}
		if err := c.handleMessage(msgType, msg, conn); err != nil {
			fmt.Fprintf(os.Stderr, "[BackendClient] handleMessage error: %v\n", err)
			return err
		}
	}
}

// handleMessage processes a single incoming message and sends any response if needed.
func (c *BackendClient) handleMessage(msgType api.MessageType, msg []byte, conn net.Conn) error {
	switch msgType {
	case api.MessageType_CONNECT:
		var connectResp api.ConnectResponse
		if err := proto.Unmarshal(msg, &connectResp); err != nil {
			return fmt.Errorf("failed to unmarshal CONNECT resp: %w", err)
		}
		if connectResp.Error != "" {
			return fmt.Errorf("CONNECT handshake failed: %s", connectResp.Error)
		}
		c.handshakeDone = true
		fmt.Println("[BackendClient] CONNECT handshake succeeded")
		return nil

	case api.MessageType_LIST_PLUGINS_REQUEST:
		// Application is requesting plugin list; reply with plugin names
		var req api.ListPluginsRequest
		if err := proto.Unmarshal(msg, &req); err != nil {
			return fmt.Errorf("failed to unmarshal ListPluginsRequest: %w", err)
		}
		var resp api.ListPluginsResponse
		for _, pt := range c.pluginService.ListPluginTypes() {
			resp.Plugins = append(resp.Plugins, &api.PluginTypeInfo{
				Name:        pt.Name,
				Description: pt.Description,
			})
		}
		if err := c.SendMessage(conn, api.MessageType_LIST_PLUGINS_REQUEST, &resp); err != nil {
			return fmt.Errorf("failed to send ListPluginsResponse: %w", err)
		}
		fmt.Println("[BackendClient] ListPluginsResponse sent to application")
		return nil

	case api.MessageType_SHUTDOWN_REQUEST:
		// Handle graceful shutdown
		fmt.Println("[BackendClient] Received SHUTDOWN_REQUEST, initiating graceful shutdown...")

		// Stop any ongoing operations
		// TODO: Add any necessary cleanup for plugins or other services

		// Send response before shutting down
		resp := &api.ShutdownResponse{
			Success: true,
			Message: "Shutting down gracefully",
		}
		if err := c.SendMessage(conn, api.MessageType_SHUTDOWN_REQUEST, resp); err != nil {
			fmt.Fprintf(os.Stderr, "[BackendClient] Failed to send shutdown response: %v\n", err)
		}

		// Close the connection
		conn.Close()

		// Signal server to shut down
		if c.server != nil {
			if err := c.server.Shutdown(); err != nil {
				fmt.Fprintf(os.Stderr, "[BackendClient] Error during server shutdown: %v\n", err)
			}
		}

		// Exit the process after a short delay to allow the response to be sent
		go func() {
			time.Sleep(100 * time.Millisecond)
			os.Exit(0)
		}()

		return nil
	// Add other message types here
	default:
		fmt.Printf("[BackendClient] Unknown or unhandled message type: %d\n", msgType)
	}
	return nil
}
