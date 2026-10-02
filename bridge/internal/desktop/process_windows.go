package desktop

import (
	"golang.org/x/sys/windows"
	"os/exec"
	"sync"
	"syscall"
	"unsafe"
)

var consoleOnce sync.Once
var jobs sync.Map
var kernel = windows.NewLazySystemDLL("kernel32.dll")

func hideCommand(c *exec.Cmd) {
	c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_NO_WINDOW}
}
func prepareCore(c *exec.Cmd) error {
	consoleOnce.Do(func() {
		kernel.NewProc("AllocConsole").Call()
		handle, _, _ := kernel.NewProc("GetConsoleWindow").Call()
		if handle != 0 {
			windows.NewLazySystemDLL("user32.dll").NewProc("ShowWindow").Call(handle, 0)
		}
	})
	c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_NEW_PROCESS_GROUP}
	return nil
}
func interruptCore(c *exec.Cmd) error {
	r, _, err := kernel.NewProc("GenerateConsoleCtrlEvent").Call(1, uintptr(c.Process.Pid))
	if r == 0 {
		return err
	}
	return nil
}
func containCore(c *exec.Cmd) error {
	h, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return err
	}
	info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	_, err = windows.SetInformationJobObject(h, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info)))
	if err != nil {
		windows.CloseHandle(h)
		return err
	}
	p, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, uint32(c.Process.Pid))
	if err != nil {
		windows.CloseHandle(h)
		return err
	}
	defer windows.CloseHandle(p)
	if err = windows.AssignProcessToJobObject(h, p); err != nil {
		windows.CloseHandle(h)
		return err
	}
	jobs.Store(c.Process.Pid, h)
	return nil
}
func releaseCore(c *exec.Cmd) {
	if h, ok := jobs.LoadAndDelete(c.Process.Pid); ok {
		windows.CloseHandle(h.(windows.Handle))
	}
}
