//go:build !windows

package backend

import "os/exec"

func configureProcess(cmd *exec.Cmd) {}
