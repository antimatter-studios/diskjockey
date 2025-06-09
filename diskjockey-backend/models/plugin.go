package models

import (
	"time"

	"gorm.io/gorm"
)

// Plugin represents a backend plugin (e.g. Dropbox, WebDAV, etc.)
//
// Standard GORM fields: ID, CreatedAt, UpdatedAt, DeletedAt
//
// Fields:
//   Name    - the plugin's unique name (e.g. "dropbox")
//   Enabled - whether this plugin is enabled for use

type Plugin struct {
	ID        uint `gorm:"primaryKey"`
	CreatedAt time.Time
	UpdatedAt time.Time
	DeletedAt gorm.DeletedAt `gorm:"index"`

	Name    string `gorm:"uniqueIndex;not null"`
	Enabled bool   `gorm:"not null;default:true"`
}
