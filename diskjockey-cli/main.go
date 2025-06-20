package main

import (
	"fmt"
	"os"

	"github.com/christhomas/diskjockey/diskjockey-cli/ipc"
	"github.com/christhomas/diskjockey/diskjockey-cli/subcommand"
)

var debugMode bool
var backendPort int

func main() {
	args := os.Args[1:]
	// Check for --debug and --port anywhere in the arguments
	newArgs := make([]string, 0, len(args))
	for i := 0; i < len(args); i++ {
		if args[i] == "--debug" {
			debugMode = true
		} else if args[i] == "--port" && i+1 < len(args) {
			fmt.Sscanf(args[i+1], "%d", &backendPort)
			i++ // skip port value
		} else {
			newArgs = append(newArgs, args[i])
		}
	}

	if backendPort == 0 {
		fmt.Println("Error: --port <port> is required to connect to the backend over TCP.")
		usage()
		return
	}

	client, err := ipc.NewClient(fmt.Sprintf("127.0.0.1:%d", backendPort))
	if err != nil {
		fmt.Printf("Failed to connect to backend at 127.0.0.1:%d: %v\n", backendPort, err)
		os.Exit(1)
	}
	defer client.Close()

	if len(newArgs) < 1 {
		usage()
		return
	}

	switch newArgs[0] {
	case "disk-types":
		subcommand.ListDiskTypes(client)
	case "mounts":
		subcommand.ListMounts(client)
	case "ls":
		subcommand.ListDirCommand(client, newArgs[1:])
	case "cp":
		subcommand.CopyCommand(client, newArgs[1:])
	default:
		usage()
	}
}

// Update all subcommands to accept *ipc.Client instead of net.Conn
func usage() {
	fmt.Println("djctl: Disk-Jockey CLI")
	fmt.Println("Usage:")
	fmt.Println("  djctl --port <port> disk-types         # List available disk types and config templates")
	fmt.Println("  djctl --port <port> mounts             # List current mounts")
	fmt.Println("  djctl --port <port> add-mount ...      # Add a new mount (not implemented)")
	fmt.Println("  djctl --port <port> remove-mount ...   # Remove a mount (not implemented)")
	fmt.Println("  djctl --port <port> ls <mount> [path]  # List directory contents")
	fmt.Println("  --port <port> is now REQUIRED; unix sockets are no longer supported.")
}
