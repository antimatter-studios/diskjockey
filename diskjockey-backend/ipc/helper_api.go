package ipc

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"net"

	"github.com/christhomas/diskjockey/diskjockey-backend/proto/api"
	"google.golang.org/protobuf/proto"
)

type HelperAPI struct {
	conn net.Conn
}

// NewHelperAPI creates a new HelperAPI and connects to the helper on the given TCP port.
func NewHelperAPI(port int) (*HelperAPI, error) {
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		return nil, err
	}
	return &HelperAPI{conn: conn}, nil
}

// Connect sends a CONNECT message with the given role (api.Connect_ROLE_*) and waits for the response.
func (h *HelperAPI) Connect(role api.ConnectRequest_Role) error {
	connectMsg := &api.ConnectRequest{
		Role: role,
	}
	payload, err := proto.Marshal(connectMsg)
	if err != nil {
		return err
	}
	const connectTypeID = 14 // Should match your protocol's CONNECT message type ID
	var buf bytes.Buffer
	binary.Write(&buf, binary.BigEndian, uint32(len(payload)+1))
	buf.WriteByte(byte(connectTypeID))
	buf.Write(payload)
	if _, err := h.conn.Write(buf.Bytes()); err != nil {
		return err
	}
	// Read response: [4-byte length][1-byte type][payload]
	var respLenBuf [4]byte
	if _, err := h.conn.Read(respLenBuf[:]); err != nil {
		return err
	}
	respLen := binary.BigEndian.Uint32(respLenBuf[:])
	respType := make([]byte, 1)
	if _, err := h.conn.Read(respType); err != nil {
		return err
	}
	respPayload := make([]byte, respLen-1)
	if _, err := h.conn.Read(respPayload); err != nil {
		return err
	}
	var connectResp api.ConnectResponse
	if err := proto.Unmarshal(respPayload, &connectResp); err != nil {
		return err
	}
	if connectResp.Error != "" {
		return fmt.Errorf("CONNECT handshake failed: %s", connectResp.Error)
	}
	return nil
}

// Close closes the connection to the helper.
func (h *HelperAPI) Close() error {
	return h.conn.Close()
}
