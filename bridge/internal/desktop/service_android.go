//go:build android

package desktop

import (
	"errors"
	"net"
)

func dialService() (net.Conn, error) {
	return nil, errors.New("Android uses the in-process VPN service")
}

func ServiceStatus() map[string]any {
	return map[string]any{"installed": true, "approved": true, "platform": "android"}
}

func InstallService(string) error {
	return errors.New("Android VPN permission is requested when connecting")
}

func UninstallService() error {
	return errors.New("Android VPN does not use a background service")
}

func RunPlatformService() error {
	return errors.New("Android VPN runs inside the application process")
}

func verifyServicePeer(net.Conn) error {
	return errors.New("Android does not use privileged service sockets")
}

func SetAutoStart(bool, string) error { return nil }
