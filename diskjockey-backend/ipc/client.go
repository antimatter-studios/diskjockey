package ipc

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"time"

	"github.com/christhomas/diskjockey/diskjockey-backend/proto/api"
	"github.com/christhomas/diskjockey/diskjockey-backend/services"
	"google.golang.org/protobuf/proto"
)

const (
	maxMessageSize = 100 * 1024 * 1024 // 100MB
	readTimeout    = 30 * time.Second
)

type BackendClient struct {
	conn            net.Conn
	configService   *services.ConfigService
	disktypeService *services.DiskTypeService
	mountService    *services.MountService
	handshakeDone   bool
}

func NewBackendClient(conn net.Conn, config *services.ConfigService, disktypes *services.DiskTypeService, mounts *services.MountService) *BackendClient {
	return &BackendClient{
		conn:            conn,
		configService:   config,
		disktypeService: disktypes,
		mountService:    mounts,
	}
}

// SendMessage sends an Api_Message envelope over the connection.
func (c *BackendClient) SendMessage(conn net.Conn, msgType api.MessageType, pb proto.Message) error {
	payload, err := proto.Marshal(pb)
	if err != nil {
		return fmt.Errorf("failed to marshal payload: %w", err)
	}
	msg := &api.Message{
		Type:    msgType,
		Payload: payload,
	}
	msgBytes, err := proto.Marshal(msg)
	if err != nil {
		return fmt.Errorf("failed to marshal Api_Message: %w", err)
	}
	var lenBuf [4]byte
	binary.BigEndian.PutUint32(lenBuf[:], uint32(len(msgBytes)))
	fmt.Printf("[DEBUG] Sending Api_Message of type %s of %d bytes (not including 4-byte length prefix)\n", msgType.String(), len(msgBytes))
	if _, err := conn.Write(lenBuf[:]); err != nil {
		return fmt.Errorf("failed to write message length: %w", err)
	}
	if _, err := conn.Write(msgBytes); err != nil {
		return fmt.Errorf("failed to write Api_Message bytes: %w", err)
	}
	return nil
}

// ReceiveMessage reads an Api_Message envelope from the connection.
func (c *BackendClient) ReceiveMessage(conn net.Conn) (api.MessageType, []byte, error) {
	conn.SetReadDeadline(time.Now().Add(readTimeout))

	var lenBuf [4]byte
	if _, err := io.ReadFull(conn, lenBuf[:]); err != nil {
		return 0, nil, fmt.Errorf("failed to read message length: %w", err)
	}
	msgLen := binary.BigEndian.Uint32(lenBuf[:])
	if msgLen > maxMessageSize {
		return 0, nil, fmt.Errorf("message too large: %d bytes (max %d)", msgLen, maxMessageSize)
	}
	msgBytes := make([]byte, msgLen)
	if _, err := io.ReadFull(conn, msgBytes); err != nil {
		return 0, nil, fmt.Errorf("failed to read Api_Message: %w", err)
	}
	var msg api.Message
	if err := proto.Unmarshal(msgBytes, &msg); err != nil {
		return 0, nil, fmt.Errorf("failed to unmarshal Api_Message: %w", err)
	}
	return msg.Type, msg.Payload, nil
}

// Start runs the main loop for the BackendClient, reading and handling messages until the connection closes.
func (c *BackendClient) Start() {
	defer c.conn.Close()
	fmt.Println("[BackendClient] Starting message loop...")
	for {
		msgType, msg, err := c.ReceiveMessage(c.conn)
		if err != nil {
			// Timeout errors are not fatal — the client may send another message
			var netErr net.Error
			if errors.As(err, &netErr) && netErr.Timeout() {
				continue
			}
			if err != io.EOF {
				fmt.Fprintf(os.Stderr, "[BackendClient] Error reading message: %v\n", err)
			}
			break
		}
		if err := c.handleMessage(msgType, msg); err != nil {
			// Handler errors are logged but don't kill the connection
			fmt.Fprintf(os.Stderr, "[BackendClient] Error handling message type %v: %v\n", msgType, err)
		}
	}
}

// handleMessage processes a single incoming message and sends any response if needed.
func (c *BackendClient) handleMessage(msgType api.MessageType, msg []byte) error {
	switch msgType {
	case api.MessageType_CONNECT:
		var connectReq api.ConnectRequest
		if err := proto.Unmarshal(msg, &connectReq); err != nil {
			return fmt.Errorf("failed to unmarshal ConnectRequest: %w", err)
		}
		c.handshakeDone = true
		fmt.Printf("[BackendClient] CONNECT from role: %s\n", connectReq.Role.String())
		resp := &api.ConnectResponse{}
		if err := c.SendMessage(c.conn, api.MessageType_CONNECT, resp); err != nil {
			return fmt.Errorf("failed to send ConnectResponse: %w", err)
		}
		return nil

	case api.MessageType_LIST_DISK_TYPES_REQUEST:
		// Application is requesting disktype list; reply with disktype names
		var req api.ListDiskTypesRequest
		if err := proto.Unmarshal(msg, &req); err != nil {
			return fmt.Errorf("failed to unmarshal ListDiskTypesRequest: %w", err)
		}
		var resp api.ListDiskTypesResponse
		for _, dt := range c.disktypeService.ListDiskTypes() {
			resp.DiskTypes = append(resp.DiskTypes, &api.DiskTypeInfo{
				Name:        dt.Name,
				Description: dt.Description,
				// Add Config if DiskTypeInfo supports it
			})
		}
		if err := c.SendMessage(c.conn, api.MessageType_LIST_DISK_TYPES_RESPONSE, &resp); err != nil {
			return fmt.Errorf("failed to send ListDiskTypesResponse: %w", err)
		}
		fmt.Println("[BackendClient] ListDiskTypesResponse sent to application")
		return nil

	case api.MessageType_LIST_MOUNTS_REQUEST:
		// Handle ListMountsRequest
		var req api.ListMountsRequest
		if err := proto.Unmarshal(msg, &req); err != nil {
			return fmt.Errorf("failed to unmarshal ListMountsRequest: %w", err)
		}
		mounts, err := c.configService.ListMountpoints()
		resp := &api.ListMountsResponse{}
		if err != nil {
			resp.Error = err.Error()
		} else {
			for _, m := range mounts {
				diskType := m.DiskType
				config := map[string]string{}
				if m.Host != "" {
					config["host"] = m.Host
				}
				if m.Username != "" {
					config["username"] = m.Username
				}
				if m.Path != "" {
					config["path"] = m.Path
				}
				if m.Share != "" {
					config["share"] = m.Share
				}
				// Intentionally omit password and access_token from responses
				resp.Mounts = append(resp.Mounts, &api.MountInfo{
					Name:     m.Name,
					DiskType: diskType,
					Config:   config,
					MountId:  uint32(m.ID),
				})
			}
		}
		if err := c.SendMessage(c.conn, api.MessageType_LIST_MOUNTS_RESPONSE, resp); err != nil {
			return fmt.Errorf("failed to send ListMountsResponse: %w", err)
		}
		fmt.Println("[BackendClient] ListMountsResponse sent to application")
		return nil

	case api.MessageType_CREATE_MOUNT_REQUEST:
		// Handle CreateMountRequest
		var req api.CreateMountRequest
		if err := proto.Unmarshal(msg, &req); err != nil {
			resp := &api.CreateMountResponse{
				MountId: 0,
				Error:   "failed to parse CreateMountRequest: " + err.Error(),
			}
			_ = c.SendMessage(c.conn, api.MessageType_CREATE_MOUNT_RESPONSE, resp)
			return nil
		}
		fmt.Printf("[BackendClient] Received CreateMountRequest: %+v\n", req)
		mountID, err := c.configService.CreateMount(req.Name, req.DiskType, req.Config, c.disktypeService)
		fmt.Printf("[BackendClient] Created mount with ID %d, error: %v\n", mountID, err)
		resp := &api.CreateMountResponse{}
		if err != nil {
			resp.MountId = 0
			resp.Error = err.Error()
		} else {
			resp.MountId = mountID
			resp.Error = ""
		}
		if err := c.SendMessage(c.conn, api.MessageType_CREATE_MOUNT_RESPONSE, resp); err != nil {
			return fmt.Errorf("failed to send CreateMountResponse: %w", err)
		}
		fmt.Println("[BackendClient] CreateMountResponse sent to application")
		return nil

	case api.MessageType_SHUTDOWN_REQUEST:
		// Handle graceful shutdown
		fmt.Println("[BackendClient] Received SHUTDOWN_REQUEST, initiating graceful shutdown...")

		// Stop any ongoing operations
		// TODO: Add any necessary cleanup for disk types or other services

		// Send response before shutting down
		resp := &api.ShutdownResponse{
			Success: true,
			Message: "Shutting down gracefully",
		}
		if err := c.SendMessage(c.conn, api.MessageType_SHUTDOWN_RESPONSE, resp); err != nil {
			fmt.Fprintf(os.Stderr, "[BackendClient] Failed to send shutdown response: %v\n", err)
		}

		// Connection will be closed by the deferred c.conn.Close() in Start()

		return nil

	case api.MessageType_MOUNT_REQUEST:
		var req api.MountRequest
		if err := proto.Unmarshal(msg, &req); err != nil {
			return fmt.Errorf("failed to unmarshal MountRequest: %w", err)
		}
		resp := &api.MountResponse{}
		if err := c.mountService.Mount(req.MountId); err != nil {
			resp.Error = err.Error()
		}
		if err := c.SendMessage(c.conn, api.MessageType_MOUNT_RESPONSE, resp); err != nil {
			return fmt.Errorf("failed to send MountResponse: %w", err)
		}
		fmt.Printf("[BackendClient] MountResponse sent (mount_id=%d)\n", req.MountId)
		return nil

	case api.MessageType_UNMOUNT_REQUEST:
		var req api.UnmountRequest
		if err := proto.Unmarshal(msg, &req); err != nil {
			return fmt.Errorf("failed to unmarshal UnmountRequest: %w", err)
		}
		resp := &api.UnmountResponse{}
		if err := c.mountService.Unmount(req.MountId); err != nil {
			resp.Error = err.Error()
		}
		if err := c.SendMessage(c.conn, api.MessageType_UNMOUNT_RESPONSE, resp); err != nil {
			return fmt.Errorf("failed to send UnmountResponse: %w", err)
		}
		fmt.Printf("[BackendClient] UnmountResponse sent (mount_id=%d)\n", req.MountId)
		return nil

	case api.MessageType_DELETE_MOUNT_REQUEST:
		var req api.DeleteMountRequest
		if err := proto.Unmarshal(msg, &req); err != nil {
			return fmt.Errorf("failed to unmarshal DeleteMountRequest: %w", err)
		}
		resp := &api.DeleteMountResponse{}
		// Unmount first if active, ignore error if not mounted
		_ = c.mountService.Unmount(req.MountId)
		if err := c.configService.DeleteMount(req.MountId); err != nil {
			resp.Error = err.Error()
		}
		if err := c.SendMessage(c.conn, api.MessageType_DELETE_MOUNT_RESPONSE, resp); err != nil {
			return fmt.Errorf("failed to send DeleteMountResponse: %w", err)
		}
		fmt.Printf("[BackendClient] DeleteMountResponse sent (mount_id=%d)\n", req.MountId)
		return nil

	case api.MessageType_LIST_DIR_REQUEST:
		var req api.ListDirRequest
		if err := proto.Unmarshal(msg, &req); err != nil {
			return fmt.Errorf("failed to unmarshal ListDirRequest: %w", err)
		}
		resp := &api.ListDirResponse{}
		files, err := c.mountService.ListDir(req.MountId, req.Path)
		if err != nil {
			resp.Error = err.Error()
		} else {
			for _, f := range files {
				resp.Files = append(resp.Files, &api.FileInfo{
					Name:  f.Name,
					Size:  f.Size,
					IsDir: f.IsDir,
				})
			}
		}
		if err := c.SendMessage(c.conn, api.MessageType_LIST_DIR_RESPONSE, resp); err != nil {
			return fmt.Errorf("failed to send ListDirResponse: %w", err)
		}
		return nil

	case api.MessageType_READ_FILE_REQUEST:
		var req api.ReadFileRequest
		if err := proto.Unmarshal(msg, &req); err != nil {
			return fmt.Errorf("failed to unmarshal ReadFileRequest: %w", err)
		}
		resp := &api.ReadFileResponse{}
		data, err := c.mountService.ReadFile(req.MountId, req.Path)
		if err != nil {
			resp.Error = err.Error()
		} else {
			resp.Data = data
		}
		if err := c.SendMessage(c.conn, api.MessageType_READ_FILE_RESPONSE, resp); err != nil {
			return fmt.Errorf("failed to send ReadFileResponse: %w", err)
		}
		return nil

	case api.MessageType_STAT_REQUEST:
		var req api.StatRequest
		if err := proto.Unmarshal(msg, &req); err != nil {
			return fmt.Errorf("failed to unmarshal StatRequest: %w", err)
		}
		resp := &api.StatResponse{}
		info, err := c.mountService.StatFile(req.MountId, req.Path)
		if err != nil {
			resp.Error = err.Error()
		} else {
			resp.Info = &api.FileInfo{
				Name:  info.Name,
				Size:  info.Size,
				IsDir: info.IsDir,
			}
		}
		if err := c.SendMessage(c.conn, api.MessageType_STAT_RESPONSE, resp); err != nil {
			return fmt.Errorf("failed to send StatResponse: %w", err)
		}
		return nil

	default:
		fmt.Printf("[BackendClient] Unknown or unhandled message type: %d\n", msgType)
	}
	return nil
}
