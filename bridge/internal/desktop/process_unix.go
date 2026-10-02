//go:build !windows

package desktop

import (
	"os/exec"
	"syscall"
)

func hideCommand(c *exec.Cmd)         {}
func prepareCore(c *exec.Cmd) error   { c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}; return nil }
func interruptCore(c *exec.Cmd) error { return c.Process.Signal(syscall.SIGTERM) }
func containCore(c *exec.Cmd) error   { return nil }
func releaseCore(c *exec.Cmd)         {}
