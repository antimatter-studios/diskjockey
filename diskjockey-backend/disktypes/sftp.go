package disktypes

import (
	"fmt"
	"io"
	"net"
	"os"
	"time"

	"github.com/christhomas/diskjockey/diskjockey-backend/models"
	"github.com/christhomas/diskjockey/diskjockey-backend/types"
	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/agent"
)

// SFTPDiskType implements the DiskType interface for SFTP-backed mounts
// Config expects: host, port, username, password, root

type SFTPDiskType struct{}

type SFTPBackend struct {
	mount   *models.Mount
	sshConn *ssh.Client
	client  *sftp.Client
	path    string // cached after connect
}

func (SFTPDiskType) New(mount *models.Mount) (types.Backend, error) {
	b := &SFTPBackend{mount: mount}
	if err := b.connect(); err != nil {
		return nil, err
	}
	return b, nil
}

func (SFTPDiskType) Name() string {
	return "sftp"
}

func (SFTPDiskType) Description() string {
	return "SFTP-backed remote filesystem mount"
}

func (SFTPDiskType) ConfigTemplate() types.DiskTypeConfigTemplate {
	return types.DiskTypeConfigTemplate{
		"host": types.DiskTypeConfigField{
			Type:        "string",
			Description: "Remote SFTP server hostname",
			Required:    true,
		},
		"port": types.DiskTypeConfigField{
			Type:        "integer",
			Description: "SFTP port (default 22)",
			Required:    true,
		},
		"username": types.DiskTypeConfigField{
			Type:        "string",
			Description: "Username for SFTP",
			Required:    true,
		},
		"password": types.DiskTypeConfigField{
			Type:        "string",
			Description: "Password for SFTP (not secure, demo only)",
			Required:    false,
		},
		"use_ssh_agent": types.DiskTypeConfigField{
			Type:        "bool",
			Description: "Use SSH agent for authentication (if available)",
			Required:    false,
		},
		"path": types.DiskTypeConfigField{
			Type:        "string",
			Description: "Remote path prefix for all requests",
			Required:    true,
		},
	}
}

func (b *SFTPBackend) connect() error {
	host := b.mount.Host
	port := b.mount.Port
	username := b.mount.Username
	password := b.mount.Password
	b.path = b.mount.Path
	useAgent := false // Set this based on a future field if needed

	if host == "" || username == "" {
		return fmt.Errorf("missing required sftp config fields")
	}

	addr := fmt.Sprintf("%s:%d", host, port)
	auths := []ssh.AuthMethod{}
	if password != "" {
		auths = append(auths, ssh.Password(password))
	}

	if useAgent {
		sshAgentSock := os.Getenv("SSH_AUTH_SOCK")
		if sshAgentSock != "" {
			agentConn, err := net.Dial("unix", sshAgentSock)
			if err == nil {
				auths = append(auths, ssh.PublicKeysCallback(agent.NewClient(agentConn).Signers))
			}
		}
	}

	if len(auths) == 0 {
		return fmt.Errorf("no authentication method provided (set password or use_ssh_agent)")
	}

	sshConfig := &ssh.ClientConfig{
		User:            username,
		Auth:            auths,
		HostKeyCallback: ssh.InsecureIgnoreHostKey(), // WARNING: for demo only
		Timeout:         5 * time.Second,
	}

	sshConn, err := ssh.Dial("tcp", addr, sshConfig)
	if err != nil {
		return fmt.Errorf("ssh dial failed: %w", err)
	}

	sftpClient, err := sftp.NewClient(sshConn)
	if err != nil {
		sshConn.Close()
		return fmt.Errorf("sftp client failed: %w", err)
	}

	b.sshConn = sshConn
	b.client = sftpClient

	return nil
}

func (b *SFTPBackend) Stat(path string) (types.FileInfo, error) {
	return types.FileInfo{}, fmt.Errorf("stat not implemented for sftp")
}

func (b *SFTPBackend) List(path string) ([]types.FileInfo, error) {
	absPath := b.path + path
	files, err := b.client.ReadDir(absPath)
	if err != nil {
		return nil, err
	}

	var out []types.FileInfo
	for _, f := range files {
		out = append(out, types.FileInfo{
			Name:  f.Name(),
			IsDir: f.IsDir(),
			Size:  f.Size(),
		})
	}

	return out, nil
}

func (b *SFTPBackend) Read(path string) ([]byte, error) {
	absPath := b.path + path
	f, err := b.client.Open(absPath)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return io.ReadAll(f)
}

func (b *SFTPBackend) Write(path string, data []byte) error {
	absPath := b.path + path

	f, err := b.client.Create(absPath)
	if err != nil {
		return err
	}
	defer f.Close()

	_, err = f.Write(data)
	return err
}

func (b *SFTPBackend) Delete(path string) error {
	absPath := b.path + path
	return b.client.Remove(absPath)
}

func (b *SFTPBackend) Close() error {
	var firstErr error
	if b.client != nil {
		if err := b.client.Close(); err != nil {
			firstErr = err
		}
	}
	if b.sshConn != nil {
		if err := b.sshConn.Close(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

func (b *SFTPBackend) Reconnect() error {
	if b.client != nil {
		b.client.Close()
	}
	if b.sshConn != nil {
		b.sshConn.Close()
	}
	b.client = nil
	b.sshConn = nil

	return b.connect()
}
