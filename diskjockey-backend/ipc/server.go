package ipc

import (
	"fmt"
	"net"
	"os"
	"sync"
	"time"

	"github.com/christhomas/diskjockey/diskjockey-backend/services"
)

type BackendServer struct {
	configService   *services.ConfigService
	disktypeService *services.DiskTypeService
	mountService    *services.MountService
	shutdownChan    chan struct{} // Channel to signal shutdown
	doneChan        chan struct{} // Closed when server has fully stopped
	listener        net.Listener // Store the listener for graceful shutdown
	lastActivityMu  sync.Mutex   // Protects lastActivity
	lastActivity    time.Time    // Last time of activity
	shutdownOnce    sync.Once
}

func NewBackendServer(config *services.ConfigService, disktypes *services.DiskTypeService, mounts *services.MountService) *BackendServer {
	s := &BackendServer{
		configService:   config,
		disktypeService: disktypes,
		mountService:    mounts,
		shutdownChan:    make(chan struct{}),
		doneChan:        make(chan struct{}),
	}
	s.lastActivity = time.Now()
	return s
}

// Done returns a channel that is closed when the server has fully stopped.
func (s *BackendServer) Done() <-chan struct{} {
	return s.doneChan
}

// RunServer starts the backend server and returns the port it's listening on.
// If enableTimeout is true, the server will shut down after 5 minutes of inactivity.
func (s *BackendServer) RunServer(enableTimeout bool) (int, error) {
	var err error
	s.listener, err = net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, fmt.Errorf("failed to listen: %w", err)
	}

	addr := s.listener.Addr().(*net.TCPAddr)
	port := addr.Port

	// Start monitoring inactivity (only if enabled)
	if enableTimeout {
		go s.monitorInactivity(5 * time.Minute)
	}

	// Start accepting connections in a goroutine
	go func() {
		fmt.Println("Server started, accepting connections...")
		for {
			conn, err := s.listener.Accept()
			s.updateActivity() // Update last activity on every accepted connection
			if err != nil {
				// Check if the error is due to the listener being closed
				select {
				case <-s.shutdownChan:
					fmt.Println("Shutting down")
					// Normal shutdown, exit the loop
					return
				default:
					// Unexpected error
					fmt.Fprintf(os.Stderr, "accept error: %v\n", err)
				}
				continue
			}
			client := NewBackendClient(conn, s.configService, s.disktypeService, s.mountService)
			go client.Start()
		}
	}()

	// Write directly to stdout with a newline and flush
	fmt.Printf("PORT=%d\n", port)
	os.Stdout.Sync()
	// Add a small delay to ensure the output is processed
	time.Sleep(100 * time.Millisecond)

	return port, nil
}

// Shutdown gracefully shuts down the server
func (s *BackendServer) Shutdown() error {
	var err error
	s.shutdownOnce.Do(func() {
		close(s.shutdownChan) // Signal all goroutines to stop
		if s.listener != nil {
			err = s.listener.Close()
		}
		close(s.doneChan)
	})
	return err
}

// updateActivity records the current time as the last activity
func (s *BackendServer) updateActivity() {
	s.lastActivityMu.Lock()
	s.lastActivity = time.Now()
	s.lastActivityMu.Unlock()
}

// monitorInactivity shuts down the server if there is no activity for the given timeout
func (s *BackendServer) monitorInactivity(timeout time.Duration) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			s.lastActivityMu.Lock()
			idle := time.Since(s.lastActivity)
			s.lastActivityMu.Unlock()
			if idle > timeout {
				fmt.Printf("No activity for %v, shutting down.\n", timeout)
				s.Shutdown()
				return
			}
		case <-s.shutdownChan:
			return
		}
	}
}
