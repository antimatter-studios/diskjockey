package models

import (
	"time"

	"gorm.io/gorm"
)

// Config represents a key-value configuration setting for the application.
//
// Fields:
//   Key   - configuration key (unique)
//   Value - configuration value (string)
//
// Standard GORM fields: ID, CreatedAt, UpdatedAt, DeletedAt

type Config struct {
	ID        uint `gorm:"primaryKey"`
	CreatedAt time.Time
	UpdatedAt time.Time
	DeletedAt gorm.DeletedAt `gorm:"index"`

	Key   string `gorm:"uniqueIndex;not null"`
	Value string `gorm:"not null"`
}
