package subcommand

import (
	"fmt"
	"os"

	"github.com/christhomas/diskjockey/diskjockey-backend/proto/api"
	"github.com/christhomas/diskjockey/diskjockey-cli/ipc"
	"google.golang.org/protobuf/proto"
)

func ListDiskTypes(client *ipc.Client) {
	if err := client.SendMessage(api.MessageType_LIST_DISK_TYPES_REQUEST, &api.ListDiskTypesRequest{}); err != nil {
		fmt.Println("Send ListDiskTypesRequest error:", err)
		os.Exit(1)
	}
	typeReceived, payload, err := client.ReceiveMessage()
	if err != nil {
		fmt.Println("Receive ListDiskTypesResponse error:", err)
		os.Exit(1)
	}
	if typeReceived != api.MessageType_LIST_DISK_TYPES_RESPONSE {
		fmt.Printf("Unexpected resp type for ListDiskTypesResponse: %v\n", typeReceived)
		os.Exit(1)
	}
	resp := &api.ListDiskTypesResponse{}
	if err := proto.Unmarshal(payload, resp); err != nil {
		fmt.Println("Unmarshal error:", err)
		os.Exit(1)
	}
	if resp.Error != "" {
		fmt.Println("Server error:", resp.Error)
		os.Exit(1)
	}
	for _, diskType := range resp.DiskTypes {
		fmt.Printf("DiskType: %s\n  Description: %s\n", diskType.Name, diskType.Description)
		for _, configField := range diskType.ConfigFields {
			fmt.Printf("    - %s (%s) required=%v: %s\n", configField.Name, configField.Type, configField.Required, configField.Description)
		}
	}
}
