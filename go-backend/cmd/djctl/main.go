package main

import (
	"fmt"
	"os"
)

const socketPath = "/tmp/diskjockey.sock"

var debugMode bool

func main() {
	args := os.Args[1:]
	// Check for --debug anywhere in the arguments
	newArgs := make([]string, 0, len(args))
	for _, arg := range args {
		if arg == "--debug" {
			debugMode = true
		} else {
			newArgs = append(newArgs, arg)
		}
	}
	if len(newArgs) < 1 {
		usage()
		return
	}
	switch newArgs[0] {
	case "plugins":
		listPlugins()
	case "mounts":
		listMounts()
	case "ls":
		lsCommand(newArgs[1:])
	case "cp":
		cpCommand(newArgs[1:])
	default:
		usage()
	}
}

func usage() {
	fmt.Println("djctl: Disk-Jockey CLI")
	fmt.Println("Usage:")
	fmt.Println("  djctl plugins         # List available plugin types and config templates")
	fmt.Println("  djctl mounts          # List current mounts")
	fmt.Println("  djctl add-mount ...   # Add a new mount (not implemented)")
	fmt.Println("  djctl remove-mount ...# Remove a mount (not implemented)")
	fmt.Println("  djctl ls <mount> [path] # List directory contents")
}
