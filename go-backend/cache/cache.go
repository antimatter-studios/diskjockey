package cache

import (
	"sync"
	"time"
)

// CacheManager manages local file cache (LRU, pinning, checksums)
type CacheManager struct {
	RootDir string
	mu      sync.Mutex
	files   map[string]*CacheEntry // key: cache path
	maxSize int64
}

type CacheEntry struct {
	Path     string
	Size     int64
	Pinned   bool
	Checksum string
	LastUsed time.Time
}

// NewCacheManager initializes the cache manager at the given root directory
func NewCacheManager(root string, maxSize int64) *CacheManager {
	return &CacheManager{
		RootDir: root,
		files:   make(map[string]*CacheEntry),
		maxSize: maxSize,
	}
}

// AddFile adds a file to the cache (dummy implementation)
func (c *CacheManager) AddFile(path string, size int64, pinned bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.files[path] = &CacheEntry{Path: path, Size: size, Pinned: pinned, LastUsed: time.Now()}
}

// EvictLRU evicts least recently used files until under maxSize
func (c *CacheManager) EvictLRU() {
	// TODO: Implement LRU eviction logic
}

// GetFile returns cache entry if present
func (c *CacheManager) GetFile(path string) (*CacheEntry, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	entry, ok := c.files[path]
	if ok {
		entry.LastUsed = time.Now()
	}
	return entry, ok
}
