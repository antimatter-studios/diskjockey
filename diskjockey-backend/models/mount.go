package models

import (
	"time"
	"gorm.io/gorm"
)

// Mount represents a user-defined mount point for a plugin-backed filesystem.
//
// Fields:
//   PluginID     - foreign key to Plugin table
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
	ID          uint           `gorm:"primaryKey"`
	CreatedAt   time.Time
	UpdatedAt   time.Time
	DeletedAt   gorm.DeletedAt `gorm:"index"`

	PluginID    uint           `gorm:"not null;index"` // Foreign key to Plugin
	Plugin      Plugin         `gorm:"constraint:OnUpdate:CASCADE,OnDelete:SET NULL;"`

	Name        string         `gorm:"not null"`
	Path        string         `gorm:"not null"`
	Host        string
	Port        int
	Username    string
	Password    string
	AccessToken string
	Share       string

	IsMounted   bool           `gorm:"not null;default:false"`
}
