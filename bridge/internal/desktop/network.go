package desktop

import (
	"fmt"
	"net"
	"sort"
)

type NetworkInterface struct {
	Name string `json:"name"`
}

func ListNetworkInterfaces() ([]NetworkInterface, error) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, err
	}
	result := []NetworkInterface{}
	for _, iface := range interfaces {
		if iface.Flags&net.FlagLoopback != 0 || iface.Flags&net.FlagUp == 0 {
			continue
		}
		addresses, err := iface.Addrs()
		if err != nil || len(addresses) == 0 {
			continue
		}
		result = append(result, NetworkInterface{Name: iface.Name})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	return result, nil
}

func validateTunInterface(name string) error {
	iface, err := net.InterfaceByName(name)
	if err != nil || iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
		return fmt.Errorf("TUN outbound network %q is unavailable; connect it or choose another network on Home before connecting", name)
	}
	return nil
}
