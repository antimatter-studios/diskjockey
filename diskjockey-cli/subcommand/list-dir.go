package subcommand

import (
	"fmt"
	"os"

	"github.com/christhomas/diskjockey/diskjockey-backend/proto/api"
	"github.com/christhomas/diskjockey/diskjockey-cli/ipc"
	"google.golang.org/protobuf/proto"
)

// debugMode is set in main.go
func ListDirCommand(client *ipc.Client, args []string) {
	if len(args) < 1 {
		fmt.Println("Usage: djctl ls <mount> [path]")
		os.Exit(1)
	}
	mount := args[0]
	path := "/"
	if len(args) > 1 {
		path = args[1]
	}
	// Query backend for mount list to resolve mount name to mount_id
	if err := client.SendMessage(api.MessageType_LIST_MOUNTS_REQUEST, &api.ListMountsRequest{}); err != nil {
		fmt.Println("Send ListMountsRequest error:", err)
		os.Exit(1)
	}
	typeReceived, payload, err := client.ReceiveMessage()
	if err != nil {
		fmt.Println("Receive ListMountsResponse error:", err)
		os.Exit(1)
	}
	if typeReceived != api.MessageType_LIST_MOUNTS_REQUEST {
		fmt.Printf("Unexpected resp type for ListMountsResponse: %v\n", typeReceived)
		os.Exit(1)
	}
	mountsResp := &api.ListMountsResponse{}
	if err := proto.Unmarshal(payload, mountsResp); err != nil {
		fmt.Println("Unmarshal ListMountsResponse error:", err)
		os.Exit(1)
	}
	if mountsResp.Error != "" {
		fmt.Println("Server error (mounts):", mountsResp.Error)
		os.Exit(1)
	}
	var mountID uint32
	found := false
	for _, m := range mountsResp.Mounts {
		if m.Name == mount {
			mountID = m.MountId
			found = true
			break
		}
	}
	if !found {
		fmt.Printf("Mount '%s' not found\n", mount)
		os.Exit(1)
	}
	// --- ListDirRequest ---
	if err := client.SendMessage(api.MessageType_LIST_DIR_REQUEST, &api.ListDirRequest{
		MountId: mountID,
		Path:    path,
	}); err != nil {
		fmt.Println("Send ListDirRequest error:", err)
		os.Exit(1)
	}
	typeReceived, payload, err = client.ReceiveMessage()
	if err != nil {
		fmt.Println("Receive ListDirResponse error:", err)
		os.Exit(1)
	}
	if typeReceived != api.MessageType_LIST_DIR_REQUEST {
		fmt.Printf("Unexpected resp type for ListDirResponse: %v\n", typeReceived)
		os.Exit(1)
	}
	resp := &api.ListDirResponse{}
	if err := proto.Unmarshal(payload, resp); err != nil {
		fmt.Println("Unmarshal ListDirResponse error:", err)
		os.Exit(1)
	}
	if resp.Error != "" {
		fmt.Println("Server error:", resp.Error)
		os.Exit(1)
	}
	for _, f := range resp.Files {
		kind := "file"
		if f.IsDir {
			kind = "dir"
		}
		fmt.Printf("%s\t%s\t%d\n", kind, f.Name, f.Size)
	}
}
