package subcommand

import (
	"fmt"
	"os"

	"github.com/christhomas/diskjockey/diskjockey-backend/proto/api"
	"github.com/christhomas/diskjockey/diskjockey-cli/ipc"
	"google.golang.org/protobuf/proto"
)

func ListMounts(client *ipc.Client) {
	if err := client.SendMessage(api.MessageType_LIST_MOUNTS_REQUEST, &api.ListMountsRequest{}); err != nil {
		fmt.Println("Send ListMountsRequest error:", err)
		os.Exit(1)
	}
	typeReceived, payload, err := client.ReceiveMessage()
	if err != nil {
		fmt.Println("Receive ListMountsResponse error:", err)
		os.Exit(1)
	}
	if typeReceived != api.MessageType_LIST_MOUNTS_RESPONSE {
		fmt.Printf("Unexpected resp type for ListMountsResponse: %v\n", typeReceived)
		os.Exit(1)
	}
	resp := &api.ListMountsResponse{}
	if err := proto.Unmarshal(payload, resp); err != nil {
		fmt.Println("Unmarshal error:", err)
		os.Exit(1)
	}
	if resp.Error != "" {
		fmt.Println("Server error:", resp.Error)
		os.Exit(1)
	}
	for _, m := range resp.Mounts {
		fmt.Printf("Mount: %s (disk type: %s)\n", m.Name, m.DiskType)
	}
}
