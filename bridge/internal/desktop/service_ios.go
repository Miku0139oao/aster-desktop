//go:build ios

package desktop

import (
	"errors"
	"net"
)

func dialService() (net.Conn, error) {
	return nil, errors.New("iOS uses the NetworkExtension provider")
}

func ServiceStatus() map[string]any {
	return map[string]any{"installed": true, "approved": true, "platform": "ios"}
}

func InstallService(string) error {
	return errors.New("iOS VPN permission is requested by the system")
}

func UninstallService() error {
	return errors.New("iOS uses a NetworkExtension, not a background service")
}

func RunPlatformService() error {
	return errors.New("iOS VPN runs inside the NetworkExtension process")
}

func verifyServicePeer(net.Conn) error {
	return errors.New("iOS does not use privileged service sockets")
}

func SetAutoStart(bool, string) error { return nil }
