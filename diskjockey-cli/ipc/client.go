package ipc

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"

	"github.com/christhomas/diskjockey/diskjockey-backend/proto/api"
	"google.golang.org/protobuf/proto"
)

type Client struct {
	conn net.Conn
}

func NewClient(addr string) (*Client, error) {
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		return nil, err
	}
	return &Client{conn: conn}, nil
}

func (c *Client) Close() error {
	return c.conn.Close()
}

func (c *Client) SendMessage(msgType api.MessageType, pb proto.Message) error {
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
	if _, err := c.conn.Write(lenBuf[:]); err != nil {
		return fmt.Errorf("failed to write message length: %w", err)
	}
	if _, err := c.conn.Write(msgBytes); err != nil {
		return fmt.Errorf("failed to write Api_Message bytes: %w", err)
	}
	return nil
}

func (c *Client) ReceiveMessage() (api.MessageType, []byte, error) {
	var lenBuf [4]byte
	if _, err := io.ReadFull(c.conn, lenBuf[:]); err != nil {
		return 0, nil, fmt.Errorf("failed to read message length: %w", err)
	}
	msgLen := binary.BigEndian.Uint32(lenBuf[:])
	msgBytes := make([]byte, msgLen)
	if _, err := io.ReadFull(c.conn, msgBytes); err != nil {
		return 0, nil, fmt.Errorf("failed to read Api_Message: %w", err)
	}
	n := 20
	if len(msgBytes) < n {
		n = len(msgBytes)
	}
	fmt.Printf("[DEBUG] First %d bytes (CLI): % x\n", n, msgBytes[:n])
	var msg api.Message
	if err := proto.Unmarshal(msgBytes, &msg); err != nil {
		return 0, nil, fmt.Errorf("failed to unmarshal Api_Message: %w", err)
	}
	return msg.Type, msg.Payload, nil
}
