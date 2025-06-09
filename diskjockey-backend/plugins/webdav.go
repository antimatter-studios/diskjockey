package plugins

import (
	"fmt"
	"os"
	"runtime/debug"
	"strings"

	"github.com/christhomas/diskjockey/diskjockey-backend/models"
	"github.com/christhomas/diskjockey/diskjockey-backend/types"
	"github.com/studio-b12/gowebdav"
)

// WebDAVPlugin implements PluginType for mounting a WebDAV server as a filesystem
// Each mount gets its own root directory on the remote server

type WebDAVPlugin struct{}

type WebDAVBackend struct {
	mount      *models.Mount
	client     *gowebdav.Client
	pathPrefix string
	BaseURL    string
}

func (w WebDAVPlugin) New(mount *models.Mount) (types.Backend, error) {
	b := &WebDAVBackend{mount: mount}
	if err := b.connect(); err != nil {
		return nil, err
	}
	return b, nil
}

// PluginType interface implementation
func (w WebDAVPlugin) Name() string {
	return "webdav"
}

func (w WebDAVPlugin) Description() string {
	return "WebDAV remote filesystem plugin"
}

func (w WebDAVPlugin) ConfigTemplate() types.PluginConfigTemplate {
	return types.PluginConfigTemplate{
		"url": types.PluginConfigField{
			Type:        "string",
			Description: "WebDAV server URL (e.g. https://webdav.example.com). If omitted, specify host and port instead.",
			Required:    false,
		},
		"host": types.PluginConfigField{
			Type:        "string",
			Description: "WebDAV server host (e.g. webdav.example.com)",
			Required:    false,
		},
		"port": types.PluginConfigField{
			Type:        "integer",
			Description: "WebDAV server port (e.g. 443, 5001)",
			Required:    false,
		},
		"path": types.PluginConfigField{
			Type:        "string",
			Description: "Path prefix to prepend to all requests (e.g. /username)",
			Required:    false,
		},
		"username": types.PluginConfigField{
			Type:        "string",
			Description: "WebDAV username",
			Required:    true,
		},
		"password": types.PluginConfigField{
			Type:        "string",
			Description: "WebDAV password",
			Required:    true,
		},
	}
}

func (b *WebDAVBackend) connect() error {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "[WebDAV][PANIC] %v\n%s\n", r, debug.Stack())
		}
	}()
	fmt.Printf("[WebDAV][DEBUG] Mount config: %+v\n", b.mount)

	host := b.mount.Host
	port := b.mount.Port
	username := b.mount.Username
	password := b.mount.Password
	path := b.mount.Path

	scheme := "https"
	if host == "" {
		return fmt.Errorf("webdav: missing required config 'host'")
	}
	portStr := ""
	if port != 0 {
		portStr = fmt.Sprintf(":%d", port)
	}
	url := fmt.Sprintf("%s://%s%s", scheme, host, portStr)
	b.pathPrefix = path

	fmt.Printf("[WebDAV][DEBUG] Connecting to URL: %s\n", url)
	fmt.Printf("[WebDAV][DEBUG] Username: %s\n", username)

	b.client = gowebdav.NewClient(url, username, password)
	b.BaseURL = url

	return nil
}

func (b *WebDAVBackend) fullPath(requested string) string {
	// Always prepend b.Path (if set) to the requested path
	if b.pathPrefix != "" {
		// Ensure exactly one slash between b.Path and requested
		cleanPath := b.pathPrefix
		if !strings.HasPrefix(cleanPath, "/") {
			cleanPath = "/" + cleanPath
		}

		if strings.HasSuffix(cleanPath, "/") {
			cleanPath = strings.TrimRight(cleanPath, "/")
		}

		req := requested
		if !strings.HasPrefix(req, "/") {
			req = "/" + req
		}

		return cleanPath + req
	}

	return requested
}

func (b *WebDAVBackend) List(path string) (infos []types.FileInfo, err error) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "[WebDAV][PANIC][List] %v\n%s\n", r, debug.Stack())
			err = fmt.Errorf("panic: %v", r)
			infos = nil
		}
	}()

	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "[WebDAV][PANIC][List] %v\n%s\n", r, debug.Stack())
		}
	}()

	fmt.Printf("[WebDAV][DEBUG][List] Requested path: %s\n", path)
	fullPath := b.fullPath(path)
	fmt.Printf("[WebDAV][DEBUG][List] fullPath: %s\n", fullPath)
	baseURL := b.BaseURL
	fmt.Printf("[WebDAV][DEBUG][List] baseURL: %s\n", baseURL)
	fmt.Printf("[WebDAV][DEBUG][List] Final URL: %s%s\n", baseURL, fullPath)

	type readDirResult struct {
		files []os.FileInfo
		err   error
	}

	resultCh := make(chan readDirResult, 1)
	go func() {
		defer func() {
			if r := recover(); r != nil {
				fmt.Fprintf(os.Stderr, "[WebDAV][PANIC][ReadDir goroutine] %v\n%s\n", r, debug.Stack())
				resultCh <- readDirResult{nil, fmt.Errorf("panic in ReadDir: %v", r)}
			}
		}()
		files, err := b.client.ReadDir(fullPath)
		resultCh <- readDirResult{files, err}
	}()

	res := <-resultCh
	if res.err != nil {
		fmt.Fprintf(os.Stderr, "[WebDAV][ERROR][List] ReadDir error: %v\n", res.err)
		return nil, res.err
	}

	for _, f := range res.files {
		infos = append(infos, types.FileInfo{
			Name:  f.Name(),
			IsDir: f.IsDir(),
			Size:  f.Size(),
		})
	}

	return infos, nil
}

func (b *WebDAVBackend) Read(path string) (data []byte, err error) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "[WebDAV][PANIC][Read] %v\n%s\n", r, debug.Stack())
			err = fmt.Errorf("panic: %v", r)
			data = nil
		}
	}()

	return b.client.Read(b.fullPath(path))
}

func (b *WebDAVBackend) Write(path string, data []byte) (err error) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "[WebDAV][PANIC][Write] %v\n%s\n", r, debug.Stack())
			err = fmt.Errorf("panic: %v", r)
		}
	}()

	return b.client.Write(b.fullPath(path), data, 0644)
}

func (b *WebDAVBackend) Delete(path string) (err error) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "[WebDAV][PANIC][Delete] %v\n%s\n", r, debug.Stack())
			err = fmt.Errorf("panic: %v", r)
		}
	}()

	return b.client.Remove(b.fullPath(path))
}

func (b *WebDAVBackend) Reconnect() error {
	return b.connect()
}
