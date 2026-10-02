package desktop

import (
	"context"
	"errors"
	"fmt"
	"github.com/Microsoft/go-winio"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unsafe"
)

const serviceName = "AsterDesktop"
const pipeName = `\\.\pipe\AsterDesktop.Service.v1`

func dialService() (net.Conn, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	return winio.DialPipeContext(ctx, pipeName)
}
func ServiceStatus() map[string]any {
	m, err := windows.OpenSCManager(nil, nil, windows.SC_MANAGER_CONNECT)
	if err != nil {
		return map[string]any{"installed": false, "platform": "windows"}
	}
	defer windows.CloseServiceHandle(m)
	name, _ := windows.UTF16PtrFromString(serviceName)
	s, err := windows.OpenService(m, name, windows.SERVICE_QUERY_STATUS)
	if err != nil {
		return map[string]any{"installed": false, "platform": "windows"}
	}
	defer windows.CloseServiceHandle(s)
	var status windows.SERVICE_STATUS
	err = windows.QueryServiceStatus(s, &status)
	return map[string]any{"installed": true, "approved": err == nil, "running": err == nil && status.CurrentState == windows.SERVICE_RUNNING, "platform": "windows"}
}
func currentSID() (string, error) {
	token, err := windows.OpenCurrentProcessToken()
	if err != nil {
		return "", err
	}
	defer token.Close()
	user, err := token.GetTokenUser()
	if err != nil {
		return "", err
	}
	return user.User.Sid.String(), nil
}
func trustedServiceDir() string { return filepath.Join(os.Getenv("ProgramFiles"), "Aster Desktop") }
func InstallService(binary string) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	sid, err := currentSID()
	if err != nil {
		return err
	}
	return elevate(exe, `--install-service --owner `+sid)
}
func UninstallService() error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	return elevate(exe, "--uninstall-service")
}
func elevate(exe, args string) error {
	verb, _ := windows.UTF16PtrFromString("runas")
	file, _ := windows.UTF16PtrFromString(exe)
	params, _ := windows.UTF16PtrFromString(args)
	type shellExecuteInfo struct {
		Size                              uint32
		Mask                              uint32
		Hwnd                              uintptr
		Verb, File, Parameters, Directory *uint16
		Show                              int32
		Instance                          uintptr
		IDList                            uintptr
		Class                             *uint16
		ClassKey                          uintptr
		HotKey                            uint32
		Icon                              uintptr
		Process                           windows.Handle
	}
	info := shellExecuteInfo{Verb: verb, File: file, Parameters: params, Show: 0, Mask: 0x40 | 0x400}
	info.Size = uint32(unsafe.Sizeof(info))
	r, _, err := windows.NewLazySystemDLL("shell32.dll").NewProc("ShellExecuteExW").Call(uintptr(unsafe.Pointer(&info)))
	if r == 0 {
		return fmt.Errorf("service permission was not granted: %w", err)
	}
	defer windows.CloseHandle(info.Process)
	wait, err := windows.WaitForSingleObject(info.Process, 120000)
	if err != nil {
		return err
	}
	if wait != windows.WAIT_OBJECT_0 {
		return errors.New("service installation timed out")
	}
	var code uint32
	if err = windows.GetExitCodeProcess(info.Process, &code); err != nil {
		return err
	}
	if code != 0 {
		return errors.New("background service installation failed; use the Aster Desktop installer")
	}
	return nil
}
func InstallWindowsService(owner string) error {
	sid, err := windows.StringToSid(owner)
	if err != nil {
		return err
	}
	owner = sid.String()
	m, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer m.Disconnect()
	existing, err := m.OpenService(serviceName)
	if err == nil {
		defer existing.Close()
		if err = stopWindowsService(existing); err != nil {
			return err
		}
	}
	exe, _ := os.Executable()
	target := trustedServiceDir()
	if err = os.MkdirAll(target, 0755); err != nil {
		return err
	}
	for _, name := range []string{"aster-bridge.exe", "aster-core.exe"} {
		src := filepath.Join(filepath.Dir(exe), name)
		dst := filepath.Join(target, name)
		if !strings.EqualFold(src, dst) {
			b, err := os.ReadFile(src)
			if err != nil {
				return err
			}
			if err = AtomicWrite(dst, b, 0755); err != nil {
				return err
			}
		}
	}
	// Restrict both code and service state before creating the LocalSystem service.
	if out, err := command("icacls", target, "/inheritance:r", "/grant:r", "*S-1-5-18:(OI)(CI)F", "*S-1-5-32-544:(OI)(CI)F", "*"+owner+":(OI)(CI)RX"); err != nil {
		return fmt.Errorf("cannot protect service files: %s", out)
	}
	data := filepath.Join(os.Getenv("ProgramData"), "AsterDesktop", "service")
	if err = os.MkdirAll(data, 0700); err != nil {
		return err
	}
	if out, err := command("icacls", data, "/inheritance:r", "/grant:r", "*S-1-5-18:(OI)(CI)F", "*S-1-5-32-544:(OI)(CI)F"); err != nil {
		return fmt.Errorf("cannot protect service state: %s", out)
	}
	if err = AtomicWrite(filepath.Join(data, "owner.txt"), []byte(owner), 0600); err != nil {
		return err
	}
	if existing != nil {
		return existing.Start()
	}
	s, err := m.CreateService(serviceName, filepath.Join(target, "aster-bridge.exe"), mgr.Config{DisplayName: "Aster Desktop background service", StartType: mgr.StartAutomatic, Description: "Manages Aster Core TUN for the authorized desktop user."}, "--service")
	if err != nil {
		return err
	}
	defer s.Close()
	return s.Start()
}
func RemoveWindowsService() error {
	m, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer m.Disconnect()
	s, err := m.OpenService(serviceName)
	if err != nil {
		return err
	}
	defer s.Close()
	if err = stopWindowsService(s); err != nil {
		return err
	}
	return s.Delete()
}
func stopWindowsService(service *mgr.Service) error {
	status, err := service.Query()
	if err != nil {
		return err
	}
	if status.State == svc.Stopped {
		return nil
	}
	if _, err = service.Control(svc.Stop); err != nil {
		return err
	}
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		status, err = service.Query()
		if err != nil {
			return err
		}
		if status.State == svc.Stopped {
			return nil
		}
		time.Sleep(200 * time.Millisecond)
	}
	return errors.New("background service did not stop; try again after disconnecting")
}
func verifyServicePeer(conn net.Conn) error {
	fd, ok := conn.(interface{ Fd() uintptr })
	if !ok {
		return errors.New("service connection does not expose a pipe handle")
	}
	var pid uint32
	r, _, err := kernel.NewProc("GetNamedPipeClientProcessId").Call(fd.Fd(), uintptr(unsafe.Pointer(&pid)))
	if r == 0 {
		return err
	}
	p, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(p)
	var token windows.Token
	if err = windows.OpenProcessToken(p, windows.TOKEN_QUERY, &token); err != nil {
		return err
	}
	defer token.Close()
	user, err := token.GetTokenUser()
	if err != nil {
		return err
	}
	owner, err := os.ReadFile(filepath.Join(os.Getenv("ProgramData"), "AsterDesktop", "service", "owner.txt"))
	if err != nil {
		return err
	}
	if user.User.Sid.String() != string(owner) {
		return errors.New("service user mismatch")
	}
	return nil
}

type windowsService struct{}

func (windowsService) Execute(args []string, requests <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	status <- svc.Status{State: svc.StartPending}
	data := filepath.Join(os.Getenv("ProgramData"), "AsterDesktop", "service")
	owner, err := os.ReadFile(filepath.Join(data, "owner.txt"))
	if err != nil {
		return false, 1
	}
	listener, err := winio.ListenPipe(pipeName, &winio.PipeConfig{SecurityDescriptor: "D:P(A;;GA;;;SY)(A;;GA;;;" + string(owner) + ")", InputBufferSize: 65536, OutputBufferSize: 65536})
	if err != nil {
		return false, 2
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	core := NewServiceCore(filepath.Join(trustedServiceDir(), "aster-core.exe"), filepath.Join(data, "runtime"))
	defer core.Stop()
	go ServePrivileged(ctx, listener, core)
	status <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for change := range requests {
		switch change.Cmd {
		case svc.Interrogate:
			status <- change.CurrentStatus
		case svc.Stop, svc.Shutdown:
			status <- svc.Status{State: svc.StopPending}
			cancel()
			_ = core.Stop()
			return false, 0
		}
	}
	return false, 0
}
func RunPlatformService() error { return svc.Run(serviceName, windowsService{}) }
func SetAutoStart(enable bool, gui string) error {
	key, _, err := registry.CreateKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Run`, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer key.Close()
	if !enable {
		err = key.DeleteValue("AsterDesktop")
		if err == registry.ErrNotExist {
			return nil
		}
		return err
	}
	if !filepath.IsAbs(gui) {
		return errors.New("application path is invalid")
	}
	return key.SetStringValue("AsterDesktop", `"`+gui+`" --autostart`)
}
