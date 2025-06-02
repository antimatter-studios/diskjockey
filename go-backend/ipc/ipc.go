package ipc

import (
	"disk-jockey/go-backend/plugins"
	vfs "disk-jockey/go-backend/shared"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"os"
	"runtime/debug"

	"google.golang.org/protobuf/proto"
)

// StartServer starts a simple IPC server on the given Unix socket path
func StartServer(socketPath string, registry *plugins.PluginRegistry) error {
	if err := os.RemoveAll(socketPath); err != nil {
		return err
	}
	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		return err
	}
	defer ln.Close()
	fmt.Println("IPC server listening on", socketPath)
	for {
		conn, err := ln.Accept()
		if err != nil {
			fmt.Println("accept error:", err)
			continue
		}
		go handleConn(conn, registry)
	}
}

func handleConn(conn net.Conn, registry *plugins.PluginRegistry) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "[IPC][PANIC] %v\n%s\n", r, debug.Stack())
			// Attempt to send a generic error response for ListDirRequest (type 1)
			lenBuf := [4]byte{}
			errMsg := fmt.Sprintf("server panic: %v", r)
			resp := &vfs.ListDirResponse{Error: errMsg}
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
			var listReq vfs.ListDirRequest
			if err := proto.Unmarshal(msg, &listReq); err != nil {
				fmt.Println("unmarshal ListDirRequest error:", err)
				return
			}
			plugin, err := registry.GetBackend(listReq.Plugin)
			resp := &vfs.ListDirResponse{}
			if err != nil {
				resp.Error = err.Error()
			} else {
				files, err := plugin.List(listReq.Path)
				if err != nil {
					resp.Error = err.Error()
				} else {
					for _, f := range files {
						resp.Files = append(resp.Files, &vfs.FileInfo{
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
			var req vfs.ListPluginsRequest
			if err := proto.Unmarshal(msg, &req); err != nil {
				fmt.Println("unmarshal ListPluginsRequest error:", err)
				return
			}
			// Build response
			var resp vfs.ListPluginsResponse
			for _, pt := range registry.ListPluginTypes() {
				pti := &vfs.PluginTypeInfo{
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
			var req vfs.ListMountsRequest
			if err := proto.Unmarshal(msg, &req); err != nil {
				fmt.Println("unmarshal ListMountsRequest error:", err)
				return
			}
			var resp vfs.ListMountsResponse
			for _, m := range registry.ListMounts() {
				mi := &vfs.MountInfo{
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

		case 2: // ReadFileRequest
			var readReq vfs.ReadFileRequest
			if err := proto.Unmarshal(msg, &readReq); err != nil {
				fmt.Println("unmarshal ReadFileRequest error:", err)
				return
			}
			pluginBackend, err := registry.GetBackend(readReq.Plugin)
			resp := &vfs.ReadFileResponse{}
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
		default:
			fmt.Println("unknown or unsupported request type", msgType[0])
			return
		}
	}
}
