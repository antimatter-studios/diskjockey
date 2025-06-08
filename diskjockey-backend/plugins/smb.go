package plugins

import (
	"fmt"
	"io"
	"time"
	"github.com/hirochachacha/go-smb2"
	"net"
)

// SMBPlugin implements PluginType for SMB/CIFS shares

type SMBPlugin struct{}

func (SMBPlugin) Name() string { return "smb" }
func (SMBPlugin) Description() string { return "SMB/CIFS network share" }
func (SMBPlugin) ConfigTemplate() PluginConfigTemplate {
	return PluginConfigTemplate{
		"host": PluginConfigField{
			Type:        "string",
			Description: "SMB server hostname or IP",
			Required:    true,
		},
		"share": PluginConfigField{
			Type:        "string",
			Description: "SMB share name (case-sensitive)",
			Required:    true,
		},
		"username": PluginConfigField{
			Type:        "string",
			Description: "Username for SMB",
			Required:    true,
		},
		"password": PluginConfigField{
			Type:        "string",
			Description: "Password for SMB",
			Required:    true,
		},
		"root": PluginConfigField{
			Type:        "string",
			Description: "Remote root directory (optional)",
			Required:    false,
		},
	}
}

func (SMBPlugin) New(mountName string, configSvc ConfigServiceIface) (Backend, error) {
	b := &SMBBackend{mountName: mountName, configSvc: configSvc}
	if err := b.connect(); err != nil {
		return nil, err
	}
	return b, nil
}

// SMBBackend implements Backend for SMB/CIFS

type SMBBackend struct {
	mountName string
	configSvc ConfigServiceIface
	session   *smb2.Session
	share     *smb2.Share
	root      string
}

func (b *SMBBackend) connect() error {
	cfg, ok := b.configSvc.GetMountConfig(b.mountName)
	if !ok {
		return fmt.Errorf("SMBBackend: config for mount '%s' not found", b.mountName)
	}
	host, _ := cfg["host"].(string)
	shareName, _ := cfg["share"].(string)
	username, _ := cfg["username"].(string)
	password, _ := cfg["password"].(string)
	if host == "" || shareName == "" || username == "" {
		return fmt.Errorf("missing required smb config fields")
	}
	conn, err := net.DialTimeout("tcp", host+":445", 5*time.Second)
	if err != nil {
		return fmt.Errorf("failed to dial SMB: %w", err)
	}
	d := &smb2.Dialer{
		Initiator: &smb2.NTLMInitiator{
			User:     username,
			Password: password,
		},
	}
	session, err := d.Dial(conn)
	if err != nil {
		return fmt.Errorf("SMB dial failed: %w", err)
	}
	share, err := session.Mount(shareName)
	if err != nil {
		return fmt.Errorf("SMB mount failed: %w", err)
	}
	b.session = session
	b.share = share
	b.root = "/"
	return nil
}

func (b *SMBBackend) Reconnect() error {
	if b.share != nil {
		b.share.Umount()
	}
	if b.session != nil {
		b.session.Logoff()
	}
	return b.connect()
}

func (b *SMBBackend) List(path string) ([]FileInfo, error) {
	cleanPath := path
	if cleanPath == "" || cleanPath == "/" {
		cleanPath = "."
	} else if cleanPath[0] == '/' {
		cleanPath = cleanPath[1:]
	}
	files, err := b.share.ReadDir(cleanPath)
	if err != nil {
		return nil, err
	}
	var out []FileInfo
	for _, f := range files {
		out = append(out, FileInfo{
			Name: f.Name(),
			IsDir: f.IsDir(),
			Size: f.Size(),
		})
	}
	return out, nil
}

func (b *SMBBackend) Read(path string) ([]byte, error) {
	cleanPath := path
	if cleanPath == "" || cleanPath == "/" {
		cleanPath = "."
	} else if cleanPath[0] == '/' {
		cleanPath = cleanPath[1:]
	}
	f, err := b.share.Open(cleanPath)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return io.ReadAll(f)
}

// Write implements Backend interface
func (b *SMBBackend) Write(path string, data []byte) error {
	cleanPath := path
	if cleanPath == "" || cleanPath == "/" {
		return fmt.Errorf("cannot write to root directory")
	} else if cleanPath[0] == '/' {
		cleanPath = cleanPath[1:]
	}
	f, err := b.share.Create(cleanPath)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.Write(data)
	return err
}

// Delete implements Backend interface (stub)
func (b *SMBBackend) Delete(path string) error {
	cleanPath := path
	if cleanPath == "" || cleanPath == "/" {
		return fmt.Errorf("cannot delete root directory")
	} else if cleanPath[0] == '/' {
		cleanPath = cleanPath[1:]
	}
	return b.share.Remove(cleanPath)
}
