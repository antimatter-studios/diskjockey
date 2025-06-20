package models

import (
	"time"

	"gorm.io/gorm"
)

// Mount represents a user-defined mount point for a disk type-backed filesystem.
//
// Fields:
//   DiskType	  - name of the disk type (e.g. "webdav", "dropbox")
//   Name         - user-defined name for the mount
//   Path         - local or remote path for the mount
//   Host         - hostname of the remote disk (if applicable)
//   Port         - remote port (if applicable)
//   Username     - username for authentication
//   Password     - plain text password for authentication
//   AccessToken  - token for OAuth or similar
//   Share        - share name (for SMB, etc.)
//
// Standard GORM fields: ID, CreatedAt, UpdatedAt, DeletedAt

type Mount struct {
	ID        uint `gorm:"primaryKey"`
	CreatedAt time.Time
	UpdatedAt time.Time
	DeletedAt gorm.DeletedAt `gorm:"index"`

	DiskType string `gorm:"column:disk_type;not null;index"` // Name of the disk type (e.g. "webdav", "dropbox")

	Name        string `gorm:"not null"`
	Path        string `gorm:"not null"`
	Host        string
	Port        int
	Username    string
	Password    string
	AccessToken string
	Share       string

	IsMounted bool `gorm:"not null;default:false"`
}
