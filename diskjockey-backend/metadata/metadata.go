package metadata

import (
	"go.etcd.io/bbolt"
)

// MetadataStore wraps BoltDB for file and sync metadata

type MetadataStore struct {
	DB *bbolt.DB
}

func OpenMetadataStore(path string) (*MetadataStore, error) {
	db, err := bbolt.Open(path, 0600, nil)
	if err != nil {
		return nil, err
	}
	return &MetadataStore{DB: db}, nil
}

func (m *MetadataStore) Close() {
	if m.DB != nil {
		m.DB.Close()
	}
}

// TODO: Add methods for file metadata, sync state, journaling
