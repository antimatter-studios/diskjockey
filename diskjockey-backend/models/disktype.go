package models

import (
	"time"

	"gorm.io/gorm"
)

// DiskType represents a backend disk type (e.g. Dropbox, WebDAV, etc.)
//
// Standard GORM fields: ID, CreatedAt, UpdatedAt, DeletedAt
//
// Fields:
//   Name    - the disk type's unique name (e.g. "dropbox")
//   Enabled - whether this disk type is enabled for use

type DiskType struct {
	ID        uint `gorm:"primaryKey"`
	CreatedAt time.Time
	UpdatedAt time.Time
	DeletedAt gorm.DeletedAt `gorm:"index"`

	Name    string `gorm:"uniqueIndex;not null"`
	Enabled bool   `gorm:"not null;default:true"`
}
