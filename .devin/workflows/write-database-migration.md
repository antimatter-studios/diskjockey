---
description: How to write a new database migration for the DiskJockey backend
description_long: Step-by-step guide for writing and registering a new GORM-based database migration using the migrations system
---

# How to Write a New Database Migration

This guide explains how to add a new database migration to the DiskJockey backend using the custom GORM-based migration system. Migrations are versioned, repeatable, and run in order. Each migration is a Go function registered in the `migrations` package.

## Steps

1. **Create or edit a file in `diskjockey-backend/migrations/`**
   - You can use any filename, but convention is to use `YYYYMMDDHHMMSS_description.go`.

2. **Import required packages**
   - At minimum: `gorm.io/gorm` and `fmt`.
   - Import any other packages your migration needs (e.g., `time`, hashing libraries, your types/models).

3. **Register your migration in an `init()` function**
   - Use `RegisterMigration(<name>, func(db *gorm.DB) (bool, error) { ... })`.
   - The migration name should be a unique timestamp and description (e.g., `20250128150500_create_users`).

4. **Write migration logic**
   - Use GORM to create tables, add columns, or seed data.
   - Return `(true, nil)` if the migration made changes; `(false, nil)` otherwise.
   - Handle errors by returning `(false, err)`.

## Example (Anonymized)

```go
package migrations

import (
    "fmt"
    "time"
    "gorm.io/gorm"
    // import your model types here
)

func init() {
    RegisterMigration("20250128150500_create_example_table", func(db *gorm.DB) (bool, error) {
        fmt.Print(" [up migration] creating example table... ")

        // Create a table for ExampleModel (replace with your struct)
        if err := db.AutoMigrate(&ExampleModel{}); err != nil {
            return false, err
        }

        madeChanges := false

        // Check if a default row already exists
        var count int64
        if err := db.Model(&ExampleModel{}).Where("field = ?", "value").Count(&count).Error; err != nil {
            return false, err
        }

        if count == 0 {
            madeChanges = true
            // Create a default row (replace fields as needed)
            row := &ExampleModel{
                Field: "value",
                CreatedAt: time.Now(),
            }
            if err := db.Create(row).Error; err != nil {
                return false, fmt.Errorf("failed to create default row: %v", err)
            }
        }

        fmt.Println("done")
        return madeChanges, nil
    })
}
```

## Tips
- Always use a unique migration name (timestamp + description).
- Use `AutoMigrate` for table/column changes, and standard GORM methods for data changes.
- Seed data only if it is truly required for the app to function.
- Use transactions if your migration is complex.
- Migrations are run in order and only once per database.

## Running Migrations
- Migrations are run automatically by the backend on startup via the `SQLiteService.Migrate()` method.
- You can check the `migrations` table in the database to see which migrations have run.
