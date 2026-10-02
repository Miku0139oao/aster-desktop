package desktop

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// The macOS app's native channel owns SMAppService and XPC. Its authenticated
// XPC service forwards framed requests to the Go supervisor over inherited pipes.
func dialService() (net.Conn, error) { return nil, errors.New("use the native macOS XPC channel") }
func ServiceStatus() map[string]any {
	return map[string]any{"installed": false, "native": true, "platform": "macos"}
}
func InstallService(binary string) error {
	return errors.New("use the macOS service authorization dialog")
}
func UninstallService() error { return errors.New("use the macOS service authorization dialog") }
func verifyServicePeer(conn net.Conn) error {
	return errors.New("macOS privileged requests must arrive through authenticated XPC")
}
func RunPlatformService() error {
	return errors.New("macOS service must be launched by the XPC helper")
}
func SetAutoStart(enable bool, gui string) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	dir := filepath.Join(home, "Library", "LaunchAgents")
	if err = os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	path := filepath.Join(dir, "app.astercore.desktop.login.plist")
	if !enable {
		_, _ = command("/bin/launchctl", "unload", path)
		err = os.Remove(path)
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	app := strings.Split(gui, "/Contents/")[0]
	if !strings.HasSuffix(app, ".app") {
		return errors.New("install the application before enabling login startup")
	}
	escape := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", "\"", "&quot;")
	plist := `<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>app.astercore.desktop.login</string><key>ProgramArguments</key><array><string>/usr/bin/open</string><string>` + escape.Replace(app) + `</string><string>--args</string><string>--autostart</string></array><key>RunAtLoad</key><true/></dict></plist>`
	if err = AtomicWrite(path, []byte(plist), 0600); err != nil {
		return err
	}
	_, err = command("/bin/launchctl", "load", path)
	return err
}

var _ = time.Second
