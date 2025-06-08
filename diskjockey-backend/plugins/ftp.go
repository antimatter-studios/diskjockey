package plugins

import (
	"crypto/tls"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/christhomas/diskjockey/diskjockey-backend/types"
	"github.com/jlaffaye/ftp"
)

// FTPPlugin implements PluginType for FTP and FTPS
// Config expects: host, port, username, password, root, ftps (bool)
type FTPPlugin struct{}

// FTPBackend implements Backend for FTP/FTPS

type FTPBackend struct {
	mountName string
	configSvc types.ConfigServiceInterface
	client    *ftp.ServerConn
	path      string
	ftps      bool
}

func (FTPPlugin) New(mountName string, configSvc types.ConfigServiceInterface) (types.Backend, error) {
	b := &FTPBackend{mountName: mountName, configSvc: configSvc}
	if err := b.connect(); err != nil {
		return nil, err
	}
	return b, nil
}

func (FTPPlugin) Name() string { return "ftp" }

func (FTPPlugin) Description() string {
	return "FTP/FTPS-backed remote filesystem mount"
}

func (FTPPlugin) ConfigTemplate() types.PluginConfigTemplate {
	return types.PluginConfigTemplate{
		"host": types.PluginConfigField{
			Type:        "string",
			Description: "Remote FTP server hostname",
			Required:    true,
		},
		"port": types.PluginConfigField{
			Type:        "string",
			Description: "FTP port (default 21)",
			Required:    true,
		},
		"username": types.PluginConfigField{
			Type:        "string",
			Description: "Username for FTP",
			Required:    true,
		},
		"password": types.PluginConfigField{
			Type:        "string",
			Description: "Password for FTP",
			Required:    true,
		},
		"path": types.PluginConfigField{
			Type:        "string",
			Description: "Remote path prefix for all requests",
			Required:    true,
		},
		"ftps": types.PluginConfigField{
			Type:        "bool",
			Description: "Enable FTPS (TLS) connection",
			Required:    false,
		},
	}
}

func (b *FTPBackend) connect() error {
	cfg, err := b.configSvc.GetMountConfig(b.mountName)
	if err != nil {
		return fmt.Errorf("FTPBackend: config for mount '%s' not found", b.mountName)
	}

	host, _ := cfg["host"].(string)
	port, _ := cfg["port"].(string)
	username, _ := cfg["username"].(string)
	password, _ := cfg["password"].(string)
	b.path, _ = cfg["path"].(string)
	b.ftps, _ = cfg["ftps"].(bool)
	addr := host + ":" + port

	var c *ftp.ServerConn
	if b.ftps {
		c, err = ftp.Dial(addr, ftp.DialWithTimeout(5*time.Second), ftp.DialWithTLS(&tls.Config{InsecureSkipVerify: true}))
		if err != nil {
			return err
		}
	} else {
		c, err = ftp.Dial(addr, ftp.DialWithTimeout(5*time.Second))
		if err != nil {
			return err
		}
	}

	if err := c.Login(username, password); err != nil {
		c.Quit()
		return err
	}
	b.client = c

	return nil
}

func (b *FTPBackend) isConnError(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "connection refused") || strings.Contains(msg, "use of closed network connection") || strings.Contains(msg, "EOF") || strings.Contains(msg, "broken pipe")
}

func (b *FTPBackend) withReconnect(op func() error) error {
	err := op()
	if b.isConnError(err) {
		if b.client != nil {
			b.client.Quit()
		}
		retryErr := b.connect()
		if retryErr != nil {
			return retryErr
		}
		return op()
	}
	return err
}

func (b *FTPBackend) List(path string) ([]types.FileInfo, error) {
	var result []types.FileInfo
	err := b.withReconnect(func() error {
		absPath := b.path + path
		entries, err := b.client.List(absPath)
		if err != nil {
			return err
		}
		var out []types.FileInfo
		for _, e := range entries {
			if e.Name == "." || e.Name == ".." {
				continue
			}
			out = append(out, types.FileInfo{
				Name:  e.Name,
				IsDir: e.Type == ftp.EntryTypeFolder,
				Size:  int64(e.Size),
			})
		}
		result = out
		return nil
	})
	return result, err
}

func (b *FTPBackend) Read(path string) ([]byte, error) {
	var data []byte
	err := b.withReconnect(func() error {
		absPath := b.path + path
		r, err := b.client.Retr(absPath)
		if err != nil {
			return err
		}
		defer r.Close()
		data, err = io.ReadAll(r)
		return err
	})
	return data, err
}

func (b *FTPBackend) Write(path string, data []byte) error {
	return b.withReconnect(func() error {
		absPath := b.path + path
		return b.client.Stor(absPath, strings.NewReader(string(data)))
	})
}

func (b *FTPBackend) Delete(path string) error {
	return b.withReconnect(func() error {
		absPath := b.path + path
		return b.client.Delete(absPath)
	})
}

func (b *FTPBackend) Reconnect() error {
	return b.connect()
}

func (b *FTPBackend) Close() error {
	return b.client.Quit()
}
