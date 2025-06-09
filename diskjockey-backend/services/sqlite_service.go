package services

import (
	"fmt"
	"net/url"
	"time"

	"github.com/christhomas/diskjockey/diskjockey-backend/migrations"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

// SQLiteService manages the database connection and lifecycle.
// This service provides connection pooling, migration, and lifecycle management for SQLite using GORM.

const (
	// Maximum number of open connections to the database
	maxOpenConns = 1
	// Maximum number of idle connections in the pool
	maxIdleConns = 1
	// Maximum amount of time a connection may be reused
	connMaxLifetime = time.Hour
	// Maximum amount of time a connection may remain idle
	connMaxIdleTime = 30 * time.Minute
)

// SQLiteService manages the database connection and lifecycle
// including migrations, connection pool settings, and utility methods.
type SQLiteService struct {
	db     *gorm.DB     // GORM database handle
	params SQLiteParams // Connection parameters
}

// SQLiteParams defines the configuration parameters for SQLite connection
// including WAL mode, busy timeout, foreign keys, and more.
type SQLiteParams struct {
	Path        string // Path to the SQLite database file
	Cache       string // Cache mode (shared, private)
	JournalMode string // Journal mode (WAL, DELETE, etc.)
	BusyTimeout int    // Busy timeout in milliseconds
	ForeignKeys bool   // Enable foreign key constraints
	Synchronous string // Synchronous mode
	TempStore   string // Temp store location
	FullFSync   bool   // Full fsync on commit
}

// NewSQLiteService creates a new DatabaseService instance with recommended SQLite parameters.
func NewSQLiteService(database string) *SQLiteService {
	return &SQLiteService{
		params: SQLiteParams{
			Path:        database,
			Cache:       "shared",
			JournalMode: "WAL",
			BusyTimeout: 5000,
			ForeignKeys: true,
			Synchronous: "NORMAL",
			TempStore:   "MEMORY",
			FullFSync:   true,
		},
	}
}

// buildConnectionURL creates a SQLite connection URL with the specified parameters.
func (p SQLiteParams) buildConnectionURL() string {
	params := url.Values{}
	params.Set("cache", p.Cache)
	params.Set("_journal_mode", p.JournalMode)
	params.Set("_busy_timeout", fmt.Sprintf("%d", p.BusyTimeout))
	params.Set("_foreign_keys", map[bool]string{true: "ON", false: "OFF"}[p.ForeignKeys])
	params.Set("_synchronous", p.Synchronous)
	params.Set("_temp_store", p.TempStore)
	params.Set("_fullfsync", map[bool]string{true: "ON", false: "OFF"}[p.FullFSync])

	return fmt.Sprintf("file:%s?%s", p.Path, params.Encode())
}

// connect establishes a new database connection.
// If a connection already exists, it is closed before opening a new one.
func (s *SQLiteService) connect() error {
	// Close existing connection if it exists
	if s.db != nil {
		_ = s.Stop()
	}

	// Open SQLite database with GORM using configured parameters
	db, err := gorm.Open(sqlite.Open(s.params.buildConnectionURL()), &gorm.Config{
		// Put here a way to use a GORMLogAdapter to send database logs to the apple unified logging system
	})
	if err != nil {
		return err
	}

	// Configure connection pool
	sqlDB, err := db.DB()
	if err != nil {
		return err
	}

	sqlDB.SetMaxOpenConns(maxOpenConns)
	sqlDB.SetMaxIdleConns(maxIdleConns)
	sqlDB.SetConnMaxLifetime(connMaxLifetime)
	sqlDB.SetConnMaxIdleTime(connMaxIdleTime)

	// Update service with new connection
	s.db = db

	return nil
}

// Start initializes the database connection.
// This must be called before using the database. Does not run migrations.
func (s *SQLiteService) Start() error {
	if err := s.connect(); err != nil {
		return err
	}
	return nil
}

// Stop closes the database connection.
func (s *SQLiteService) Stop() error {
	if s.db != nil {
		sqlDB, err := s.db.DB()
		if err != nil {
			return err
		}
		return sqlDB.Close()
	}
	return nil
}

// Migrate runs all registered migrations using the migrations package.
// This should be called after Start().
func (s *SQLiteService) Migrate() error {
	changedMigrations := make([]string, 0)
	if err := migrations.RunMigrations(s.db, func(name string, changed bool) {
		if changed {
			changedMigrations = append(changedMigrations, name)
		}
	}); err != nil {
		return err
	}

	// TODO: After the migrations have run, mark with device guid if needed
	// TODO: Log migration changes if needed
	for _, migration := range changedMigrations {
		fmt.Printf("Migration %s was applied\n", migration)
	}

	return nil
}

// Reconnect attempts to reconnect to the database.
func (s *SQLiteService) Reconnect() error {
	return s.connect()
}

// GetDB returns the underlying GORM DB handle.
func (s *SQLiteService) GetDB() *gorm.DB {
	return s.db
}
