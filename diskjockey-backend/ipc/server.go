package ipc

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"os"
	"runtime/debug"

	"github.com/christhomas/diskjockey/diskjockey-backend/proto/api"
	"github.com/christhomas/diskjockey/diskjockey-backend/services"
	"google.golang.org/protobuf/proto"
)

// Server encapsulates the backend server state and logic.
type Server struct {
	PluginService *services.PluginService
	ConfigService *services.ConfigService
	// SocketPath is deprecated; use TCP port instead
	SocketPath    string
}

// NewServer initializes the server using a loaded config struct.
// NewServer initializes the server using a fixed Application Support path for the socket
func NewServer(configService *services.ConfigService, pluginService *services.PluginService) (*Server, error) {
	// Get the socket path from configService (DB/config-driven)
	socketPath, err := configService.GetSocketPath()
	if err != nil {
		return nil, err
	}
	return &Server{
		ConfigService: configService,
		PluginService: pluginService,
		SocketPath:    socketPath,
	}, nil
}

// Start runs the IPC server and blocks until exit.
func (s *Server) Start() error {
	fmt.Println("Registered plugins:")
	for _, info := range s.PluginService.ListPluginTypes() {
		fmt.Printf("- %s: %s\n", info.Name, info.Description)
	}
	fmt.Println("Starting IPC server on TCP loopback (random port)")

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	defer ln.Close()
	port := ln.Addr().(*net.TCPAddr).Port
	fmt.Printf("LISTEN_PORT=%d\n", port)
	fmt.Printf("IPC server listening on 127.0.0.1:%d\n", port)
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

func (s *Server) handleConn(conn net.Conn) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "[IPC][PANIC] %v\n%s\n", r, debug.Stack())
			// Attempt to send a generic error response for ListDirRequest (type 1)
			lenBuf := [4]byte{}
			errMsg := fmt.Sprintf("server panic: %v", r)
			resp := &api.ListDirResponse{Error: errMsg}
			respBytes, err := proto.Marshal(resp)
			if err == nil {
				binary.BigEndian.PutUint32(lenBuf[:], uint32(len(respBytes)+1))
				conn.Write(lenBuf[:])
				conn.Write([]byte{1})
				conn.Write(respBytes)
			}
		}
		conn.Close()
	}()

	var lenBuf [4]byte
	for {
		// Read message length
		_, err := io.ReadFull(conn, lenBuf[:])
		if err != nil {
			if err != io.EOF {
				fmt.Println("read len error:", err)
			}
			return
		}
		msgLen := binary.BigEndian.Uint32(lenBuf[:])
		if msgLen < 1 {
			fmt.Println("invalid msgLen")
			return
		}
		// Read message type byte
		var msgType [1]byte
		_, err = io.ReadFull(conn, msgType[:])
		if err != nil {
			fmt.Println("read msgType error:", err)
			return
		}
		// Read the rest of the message
		msg := make([]byte, msgLen-1)
		_, err = io.ReadFull(conn, msg)
		if err != nil {
			fmt.Println("read msg error:", err)
			return
		}

		switch api.MessageType(msgType[0]) {
		case api.MessageType_LIST_DIR_REQUEST:
			var listReq api.ListDirRequest
			if err := proto.Unmarshal(msg, &listReq); err != nil {
				fmt.Println("unmarshal ListDirRequest error:", err)
				return
			}
			resp := &api.ListDirResponse{}
			mount, err := s.ConfigService.GetMountByID(listReq.MountId)
			if err != nil {
				resp.Error = "mount not found: " + err.Error()
			} else {
				ptype, ok := s.PluginService.LookupPluginType(mount.Plugin.Name)
				if !ok {
					resp.Error = "plugin type not registered: " + mount.Plugin.Name
				} else {
					backend, err := ptype.New(mount)
					if err != nil {
						resp.Error = "backend instantiation failed: " + err.Error()
					} else {
						files, err := backend.List(listReq.Path)
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
					}
				}
			}
			respBytes, err := proto.Marshal(resp)
			if err != nil {
				fmt.Println("marshal ListDirResponse error:", err)
				return
			}
			binary.BigEndian.PutUint32(lenBuf[:], uint32(len(respBytes)+1))
			if _, err := conn.Write(lenBuf[:]); err != nil {
				fmt.Println("write len error:", err)
				return
			}
			if _, err := conn.Write([]byte{byte(api.MessageType_LIST_DIR_REQUEST)}); err != nil {
				fmt.Println("write resp type error:", err)
				return
			}
			if _, err := conn.Write(respBytes); err != nil {
				fmt.Println("write resp error:", err)
				return
			}
			fmt.Println("Handled ListDirRequest for mount_id:", listReq.MountId, "path:", listReq.Path)

		case api.MessageType_LIST_PLUGINS_REQUEST:
			var req api.ListPluginsRequest
			if err := proto.Unmarshal(msg, &req); err != nil {
				fmt.Println("unmarshal ListPluginsRequest error:", err)
				return
			}
			// Build response
			var resp api.ListPluginsResponse
			for _, pt := range s.PluginService.ListPluginTypes() {
				pti := &api.PluginTypeInfo{
					Name:        pt.Name,
					Description: pt.Description,
				}
				resp.Plugins = append(resp.Plugins, pti)
			}
			respBytes, err := proto.Marshal(&resp)
			if err != nil {
				fmt.Println("marshal ListPluginsResponse error:", err)
				return
			}
			binary.BigEndian.PutUint32(lenBuf[:], uint32(len(respBytes)+1))
			if _, err := conn.Write(lenBuf[:]); err != nil {
				fmt.Println("write len error:", err)
				return
			}
			if _, err := conn.Write([]byte{byte(api.MessageType_LIST_PLUGINS_REQUEST)}); err != nil {
				fmt.Println("write resp type error:", err)
				return
			}
			if _, err := conn.Write(respBytes); err != nil {
				fmt.Println("write resp error:", err)
				return
			}
			fmt.Println("Handled ListPluginsRequest")

		case api.MessageType_LIST_MOUNTS_REQUEST:
			var req api.ListMountsRequest
			if err := proto.Unmarshal(msg, &req); err != nil {
				fmt.Println("unmarshal ListMountsRequest error:", err)
				return
			}
			var resp api.ListMountsResponse
			mounts, err := s.ConfigService.ListMountpoints()
			if err != nil {
				resp.Error = err.Error()
			} else {
				for _, m := range mounts {
					mi := &api.MountInfo{
						Name:       m.Name,
						PluginType: m.Plugin.Name,
					}
					resp.Mounts = append(resp.Mounts, mi)
				}
			}
			respBytes, err := proto.Marshal(&resp)
			if err != nil {
				fmt.Println("marshal ListMountsResponse error:", err)
				return
			}
			binary.BigEndian.PutUint32(lenBuf[:], uint32(len(respBytes)+1))
			if _, err := conn.Write(lenBuf[:]); err != nil {
				fmt.Println("write len error:", err)
				return
			}
			if _, err := conn.Write([]byte{byte(api.MessageType_LIST_MOUNTS_REQUEST)}); err != nil {
				fmt.Println("write resp type error:", err)
				return
			}
			if _, err := conn.Write(respBytes); err != nil {
				fmt.Println("write resp error:", err)
				return
			}
			fmt.Println("Handled ListMountsRequest")

		case api.MessageType_CREATE_MOUNT_REQUEST:
			var req api.CreateMountRequest
			if err := proto.Unmarshal(msg, &req); err != nil {
				fmt.Println("unmarshal CreateMountRequest error:", err)
				return
			}
			resp := &api.CreateMountResponse{}
			mountID, err := s.ConfigService.CreateMount(req.Name, req.PluginType, req.Config) // req.Config is map[string]string as expected
			if err != nil {
				resp.Error = err.Error()
			} else {
				resp.MountId = mountID
			}
			respBytes, err := proto.Marshal(resp)
			if err != nil {
				fmt.Println("marshal CreateMountResponse error:", err)
				return
			}
			binary.BigEndian.PutUint32(lenBuf[:], uint32(len(respBytes)+1))
			conn.Write(lenBuf[:])
			conn.Write([]byte{byte(api.MessageType_CREATE_MOUNT_REQUEST)})
			conn.Write(respBytes)

		case api.MessageType_DELETE_MOUNT_REQUEST:
			var req api.DeleteMountRequest
			if err := proto.Unmarshal(msg, &req); err != nil {
				fmt.Println("unmarshal DeleteMountRequest error:", err)
				return
			}
			resp := &api.DeleteMountResponse{}
			err := s.ConfigService.DeleteMount(req.MountId)
			if err != nil {
				resp.Error = err.Error()
			}
			respBytes, err := proto.Marshal(resp)
			if err != nil {
				fmt.Println("marshal DeleteMountResponse error:", err)
				return
			}
			binary.BigEndian.PutUint32(lenBuf[:], uint32(len(respBytes)+1))
			conn.Write(lenBuf[:])
			conn.Write([]byte{byte(api.MessageType_DELETE_MOUNT_REQUEST)})
			conn.Write(respBytes)

		case api.MessageType_MOUNT_REQUEST:
			var req api.MountRequest
			if err := proto.Unmarshal(msg, &req); err != nil {
				fmt.Println("unmarshal MountRequest error:", err)
				return
			}
			resp := &api.MountResponse{}
			err := s.ConfigService.SetMountMounted(req.MountId, true)
			if err != nil {
				resp.Error = err.Error()
			}
			respBytes, err := proto.Marshal(resp)
			if err != nil {
				fmt.Println("marshal MountResponse error:", err)
				return
			}
			binary.BigEndian.PutUint32(lenBuf[:], uint32(len(respBytes)+1))
			conn.Write(lenBuf[:])
			conn.Write([]byte{byte(api.MessageType_MOUNT_REQUEST)})
			conn.Write(respBytes)
			// Send MountStatusUpdate event
			status := api.MountStatus_MOUNTED
			if resp.Error != "" {
				status = api.MountStatus_ERROR
			}
			statusUpdate := &api.MountStatusUpdate{
				MountId: req.MountId,
				Status:  status,
				Error:   resp.Error,
			}
			statusBytes, err := proto.Marshal(statusUpdate)
			if err == nil {
				binary.BigEndian.PutUint32(lenBuf[:], uint32(len(statusBytes)+1))
				conn.Write(lenBuf[:])
				conn.Write([]byte{byte(api.MessageType_MOUNT_STATUS_UPDATE)}) // MountStatusUpdate
				conn.Write(statusBytes)
			}

		case api.MessageType_UNMOUNT_REQUEST:
			var req api.UnmountRequest
			if err := proto.Unmarshal(msg, &req); err != nil {
				fmt.Println("unmarshal UnmountRequest error:", err)
				return
			}
			resp := &api.UnmountResponse{}
			err := s.ConfigService.SetMountMounted(req.MountId, false)
			if err != nil {
				resp.Error = err.Error()
			}
			respBytes, err := proto.Marshal(resp)
			if err != nil {
				fmt.Println("marshal UnmountResponse error:", err)
				return
			}
			binary.BigEndian.PutUint32(lenBuf[:], uint32(len(respBytes)+1))
			if _, err := conn.Write(lenBuf[:]); err != nil {
				fmt.Println("write len error:", err)
				return
			}
			if _, err := conn.Write([]byte{byte(api.MessageType_UNMOUNT_REQUEST)}); err != nil {
				fmt.Println("write resp type error:", err)
				return
			}
			if _, err := conn.Write(respBytes); err != nil {
				fmt.Println("write resp error:", err)
				return
			}
			// Send MountStatusUpdate event
			status := api.MountStatus_UNMOUNTED
			if resp.Error != "" {
				status = api.MountStatus_ERROR
			}
			statusUpdate := &api.MountStatusUpdate{
				Status: status,
				Error:  resp.Error,
			}
			statusBytes, err := proto.Marshal(statusUpdate)
			if err == nil {
				binary.BigEndian.PutUint32(lenBuf[:], uint32(len(statusBytes)+1))
				conn.Write(lenBuf[:])
				conn.Write([]byte{byte(api.MessageType_MOUNT_STATUS_UPDATE)}) // MountStatusUpdate
				conn.Write(statusBytes)
			}
		default:
			fmt.Println("unknown or unsupported request type", msgType[0])
			return
		}
	}
}
