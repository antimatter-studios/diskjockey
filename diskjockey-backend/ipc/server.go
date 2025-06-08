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
	SocketPath    string
}

// NewServer initializes the server using a loaded config struct.
func NewServer(configService *services.ConfigService, pluginService *services.PluginService) (*Server, error) {
	mounts, err := configService.ListMountpoints()
	if err != nil {
		return nil, err
	}
	for _, m := range mounts {
		if err := pluginService.AddMount(m.Name, m.Type, m.Config); err != nil {
			fmt.Printf("[Mount Error] Failed to add mount '%s': %v\n", m.Name, err)
		}
	}

	socketPath, err := configService.GetSocketPath()
	if err != nil {
		return nil, err
	}

	return &Server{
		ConfigService: configService,
		PluginService: pluginService,
		SocketPath:    socketPath}, nil
}

// Start runs the IPC server and blocks until exit.
func (s *Server) Start() error {
	fmt.Println("Registered plugins:")
	for name, enabled := range s.PluginService.ListPluginTypes() {
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

		switch msgType[0] {
		case 1: // ListDirRequest
			var listReq api.ListDirRequest
			if err := proto.Unmarshal(msg, &listReq); err != nil {
				fmt.Println("unmarshal ListDirRequest error:", err)
				return
			}
			plugin, err := s.PluginService.GetBackend(listReq.Plugin)
			resp := &api.ListDirResponse{}
			if err != nil {
				resp.Error = err.Error()
			} else {
				files, err := plugin.List(listReq.Path)
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
			respBytes, err := proto.Marshal(resp)
			if err != nil {
				fmt.Println("marshal ListDirResponse error:", err)
				return
			}
			// Write response: len, type byte, message
			binary.BigEndian.PutUint32(lenBuf[:], uint32(len(respBytes)+1))
			if _, err := conn.Write(lenBuf[:]); err != nil {
				fmt.Println("write len error:", err)
				return
			}
			if _, err := conn.Write([]byte{1}); err != nil {
				fmt.Println("write resp type error:", err)
				return
			}
			if _, err := conn.Write(respBytes); err != nil {
				fmt.Println("write resp error:", err)
				return
			}
			fmt.Println("Handled ListDirRequest for plugin:", listReq.Plugin, "path:", listReq.Path)
		case 10: // ListPluginsRequest
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
				// Config fields removed; see PluginConfigTemplate for config schema.
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
			if _, err := conn.Write([]byte{10}); err != nil {
				fmt.Println("write resp type error:", err)
				return
			}
			if _, err := conn.Write(respBytes); err != nil {
				fmt.Println("write resp error:", err)
				return
			}
			fmt.Println("Handled ListPluginsRequest")

		case 11: // ListMountsRequest
			var req api.ListMountsRequest
			if err := proto.Unmarshal(msg, &req); err != nil {
				fmt.Println("unmarshal ListMountsRequest error:", err)
				return
			}
			var resp api.ListMountsResponse
			for _, m := range s.PluginService.ListMounts() {
				mi := &api.MountInfo{
					Name:       m.Name,
					PluginType: m.PluginType,
				}
				resp.Mounts = append(resp.Mounts, mi)
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
			if _, err := conn.Write([]byte{11}); err != nil {
				fmt.Println("write resp type error:", err)
				return
			}
			if _, err := conn.Write(respBytes); err != nil {
				fmt.Println("write resp error:", err)
				return
			}
			fmt.Println("Handled ListMountsRequest")

		case 99: // Shutdown request
			go func() {
				fmt.Println("[RDM] Received shutdown request, beginning graceful shutdown")
				// Send ACK to main app (optional, if protocol supports it)
				// Begin graceful shutdown: cancel transfers, persist queue, close connections
				s.GracefulShutdown()
				os.Exit(0)
			}()
			return

		case 2: // ReadFileRequest
			var readReq api.ReadFileRequest
			if err := proto.Unmarshal(msg, &readReq); err != nil {
				fmt.Println("unmarshal ReadFileRequest error:", err)
				return
			}
			pluginBackend, err := s.PluginService.GetBackend(readReq.Plugin)
			resp := &api.ReadFileResponse{}
			if err != nil {
				resp.Error = err.Error()
			} else {
				data, err := pluginBackend.Read(readReq.Path)
				if err != nil {
					resp.Error = err.Error()
				} else {
					resp.Data = data
				}
			}
			respBytes, err := proto.Marshal(resp)
			if err != nil {
				fmt.Println("marshal ReadFileResponse error:", err)
				return
			}
			// Write response: len, type byte, message
			binary.BigEndian.PutUint32(lenBuf[:], uint32(len(respBytes)+1))
			if _, err := conn.Write(lenBuf[:]); err != nil {
				fmt.Println("write len error:", err)
				return
			}
			if _, err := conn.Write([]byte{2}); err != nil {
				fmt.Println("write resp type error:", err)
				return
			}
			if _, err := conn.Write(respBytes); err != nil {
				fmt.Println("write resp error:", err)
				return
			}
			fmt.Println("Handled ReadFileRequest for plugin:", readReq.Plugin, "path:", readReq.Path)
		case 20: // MountRequest
			var req api.MountRequest
			if err := proto.Unmarshal(msg, &req); err != nil {
				fmt.Println("unmarshal MountRequest error:", err)
				return
			}
			// Convert config map[string]string to map[string]interface{}
			config := make(map[string]interface{})
			for k, v := range req.Config {
				config[k] = v
			}
			err := s.PluginService.AddMount(req.Name, req.PluginType, config)
			resp := &api.MountResponse{}
			if err != nil {
				resp.Error = err.Error()
			} else {
				resp.Mount = &api.MountInfo{
					Name:       req.Name,
					PluginType: req.PluginType,
					Config:     req.Config,
				}
			}
			respBytes, err := proto.Marshal(resp)
			if err != nil {
				fmt.Println("marshal MountResponse error:", err)
				return
			}
			binary.BigEndian.PutUint32(lenBuf[:], uint32(len(respBytes)+1))
			if _, err := conn.Write(lenBuf[:]); err != nil {
				fmt.Println("write len error:", err)
				return
			}
			if _, err := conn.Write([]byte{20}); err != nil {
				fmt.Println("write resp type error:", err)
				return
			}
			if _, err := conn.Write(respBytes); err != nil {
				fmt.Println("write resp error:", err)
				return
			}
			// Send MountStatusUpdate event
			status := api.MountStatus_MOUNTED
			if resp.Error != "" {
				status = api.MountStatus_ERROR
			}
			statusUpdate := &api.MountStatusUpdate{
				Name:   req.Name,
				Status: status,
				Error:  resp.Error,
			}
			statusBytes, err := proto.Marshal(statusUpdate)
			if err == nil {
				binary.BigEndian.PutUint32(lenBuf[:], uint32(len(statusBytes)+1))
				conn.Write(lenBuf[:])
				conn.Write([]byte{30}) // 30 = MountStatusUpdate
				conn.Write(statusBytes)
			}
		case 21: // UnmountRequest
			var req api.UnmountRequest
			if err := proto.Unmarshal(msg, &req); err != nil {
				fmt.Println("unmarshal UnmountRequest error:", err)
				return
			}
			// Remove mount
			err := s.PluginService.RemoveMount(req.Name)
			resp := &api.UnmountResponse{}
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
			if _, err := conn.Write([]byte{21}); err != nil {
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
				Name:   req.Name,
				Status: status,
				Error:  resp.Error,
			}
			statusBytes, err := proto.Marshal(statusUpdate)
			if err == nil {
				binary.BigEndian.PutUint32(lenBuf[:], uint32(len(statusBytes)+1))
				conn.Write(lenBuf[:])
				conn.Write([]byte{30}) // 30 = MountStatusUpdate
				conn.Write(statusBytes)
			}
		default:
			fmt.Println("unknown or unsupported request type", msgType[0])
			return
		}
	}
}
