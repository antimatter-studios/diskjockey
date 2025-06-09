package plugins

import (
	"crypto/tls"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/christhomas/diskjockey/diskjockey-backend/models"
	"github.com/christhomas/diskjockey/diskjockey-backend/types"
	"github.com/jlaffaye/ftp"
)

// FTPPlugin implements PluginType for FTP and FTPS
// Config expects: host, port, username, password, root, ftps (bool)
type FTPPlugin struct{}

// FTPBackend implements Backend for FTP/FTPS

type FTPBackend struct {
	mount  *models.Mount
	client *ftp.ServerConn
	path   string
	ftps   bool
}

func (FTPPlugin) New(mount *models.Mount) (types.Backend, error) {
	b := &FTPBackend{mount: mount}
	if err := b.connect(); err != nil {
		return nil, err
	}
	return b, nil
}

func (FTPPlugin) Name() string {
	return "ftp"
}

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
	host := b.mount.Host
	port := b.mount.Port
	username := b.mount.Username
	password := b.mount.Password
	b.path = b.mount.Path
	b.ftps = false // Set this based on a future field if needed
	addr := fmt.Sprintf("%s:%d", host, port)

	opts := []ftp.DialOption{
		ftp.DialWithTimeout(5 * time.Second),
	}

	if b.ftps {
		opts = append(opts, ftp.DialWithTLS(&tls.Config{InsecureSkipVerify: true}))
	}

	c, err := ftp.Dial(addr, opts...)
	if err != nil {
		return err
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
