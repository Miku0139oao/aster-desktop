package desktop

import (
	"context"
	"errors"
	"fmt"
	"golang.org/x/sys/unix"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const linuxServiceDir = "/usr/lib/aster-desktop"
const linuxSocket = "/run/aster-desktop/service.sock"

func dialService() (net.Conn, error) { return net.DialTimeout("unix", linuxSocket, 3*time.Second) }
func ServiceStatus() map[string]any {
	_, err := os.Stat("/etc/systemd/system/aster-desktop.service")
	out, _ := command("systemctl", "is-active", "aster-desktop.service")
	return map[string]any{"installed": err == nil, "approved": err == nil, "running": out == "active", "platform": "linux"}
}
func InstallService(binary string) error {
	exe, _ := os.Executable()
	out, err := command("pkexec", exe, "--install-service", "--owner", strconv.Itoa(os.Getuid()))
	if err != nil {
		return fmt.Errorf("background service permission was not granted: %s", bounded(out, 1000))
	}
	return nil
}
func UninstallService() error {
	exe, _ := os.Executable()
	out, err := command("pkexec", exe, "--uninstall-service")
	if err != nil {
		return fmt.Errorf("service could not be removed: %s", bounded(out, 1000))
	}
	return nil
}
func InstallLinuxService(owner string) error {
	if os.Geteuid() != 0 {
		return errors.New("service installation requires administrator permission")
	}
	uid, err := strconv.Atoi(owner)
	if err != nil || uid < 1000 {
		return errors.New("invalid service owner")
	}
	if _, err := os.Stat("/etc/systemd/system/aster-desktop.service"); err == nil {
		if out, err := command("systemctl", "stop", "aster-desktop.service"); err != nil {
			return fmt.Errorf("disconnect and stop the existing service before reinstalling: %s", out)
		}
	}
	exe, _ := os.Executable()
	if err = os.MkdirAll(linuxServiceDir, 0755); err != nil {
		return err
	}
	for _, name := range []string{"aster-bridge", "aster-core"} {
		src := filepath.Join(filepath.Dir(exe), name)
		dst := filepath.Join(linuxServiceDir, name)
		if src != dst {
			b, err := os.ReadFile(src)
			if err != nil {
				return err
			}
			if err = AtomicWrite(dst, b, 0755); err != nil {
				return err
			}
		}
	}
	data := "/var/lib/aster-desktop"
	if err = os.MkdirAll(data, 0700); err != nil {
		return err
	}
	if err = AtomicWrite(filepath.Join(data, "owner"), []byte(strconv.Itoa(uid)), 0600); err != nil {
		return err
	}
	unit := "[Unit]\nDescription=Aster Desktop TUN service\nAfter=network.target\nStartLimitIntervalSec=60\nStartLimitBurst=3\n[Service]\nType=simple\nExecStart=/usr/lib/aster-desktop/aster-bridge --service\nRuntimeDirectory=aster-desktop\nRuntimeDirectoryMode=0755\nRestart=on-failure\nRestartSec=3\nTimeoutStopSec=15\nUMask=0077\nProtectHome=true\nProtectSystem=strict\nReadWritePaths=/var/lib/aster-desktop /run/aster-desktop\nPrivateTmp=true\n[Install]\nWantedBy=multi-user.target\n"
	if err = AtomicWrite("/etc/systemd/system/aster-desktop.service", []byte(unit), 0644); err != nil {
		return err
	}
	if out, err := command("systemctl", "daemon-reload"); err != nil {
		return fmt.Errorf("cannot register service: %s", out)
	}
	out, err := command("systemctl", "enable", "--now", "aster-desktop.service")
	if err != nil {
		return fmt.Errorf("cannot start service: %s", out)
	}
	return nil
}
func RemoveLinuxService() error {
	if os.Geteuid() != 0 {
		return errors.New("service removal requires administrator permission")
	}
	if _, err := os.Stat("/etc/systemd/system/aster-desktop.service"); err == nil {
		if out, err := command("systemctl", "disable", "--now", "aster-desktop.service"); err != nil {
			return fmt.Errorf("service could not stop safely: %s", out)
		}
	}
	if err := os.Remove("/etc/systemd/system/aster-desktop.service"); err != nil && !os.IsNotExist(err) {
		return err
	}
	_, err := command("systemctl", "daemon-reload")
	return err
}
func verifyServicePeer(conn net.Conn) error {
	u, ok := conn.(*net.UnixConn)
	if !ok {
		return errors.New("invalid service connection")
	}
	raw, err := u.SyscallConn()
	if err != nil {
		return err
	}
	var cred *unix.Ucred
	var ce error
	if err = raw.Control(func(fd uintptr) { cred, ce = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED) }); err != nil {
		return err
	}
	if ce != nil {
		return ce
	}
	owner, err := os.ReadFile("/var/lib/aster-desktop/owner")
	if err != nil {
		return err
	}
	if strconv.FormatUint(uint64(cred.Uid), 10) != string(owner) {
		return errors.New("service user mismatch")
	}
	return nil
}
func RunPlatformService() error {
	if os.Geteuid() != 0 {
		return errors.New("background service requires root")
	}
	if err := os.MkdirAll(filepath.Dir(linuxSocket), 0755); err != nil {
		return err
	}
	_ = os.Remove(linuxSocket)
	listener, err := net.Listen("unix", linuxSocket)
	if err != nil {
		return err
	}
	defer os.Remove(linuxSocket)
	owner, _ := os.ReadFile("/var/lib/aster-desktop/owner")
	uid, _ := strconv.Atoi(string(owner))
	if err = os.Chown(linuxSocket, uid, -1); err != nil {
		return err
	}
	if err = os.Chmod(linuxSocket, 0600); err != nil {
		return err
	}
	ctx, cancel := signalContext()
	defer cancel()
	core := NewServiceCore(linuxServiceDir+"/aster-core", "/var/lib/aster-desktop/runtime")
	defer core.Stop()
	return ServePrivileged(ctx, listener, core)
}
func SetAutoStart(enable bool, gui string) error {
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return err
		}
		base = filepath.Join(home, ".config")
	}
	dir := filepath.Join(base, "autostart")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	path := filepath.Join(dir, "aster-desktop.desktop")
	if !enable {
		err := os.Remove(path)
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	if !filepath.IsAbs(gui) || strings.ContainsAny(gui, "\n\r") {
		return errors.New("invalid application path")
	}
	escaped := strings.NewReplacer("\\", "\\\\", "\"", "\\\"", "`", "\\`", "$", "\\$").Replace(gui)
	return AtomicWrite(path, []byte("[Desktop Entry]\nType=Application\nName=Aster Desktop\nExec=\""+escaped+"\" --autostart\nTerminal=false\nX-GNOME-Autostart-enabled=true\n"), 0600)
}

var _ = context.Background
