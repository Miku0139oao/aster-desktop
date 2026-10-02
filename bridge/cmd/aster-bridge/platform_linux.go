package main

import (
	"errors"
	"github.com/Miku0139oao/aster-desktop/bridge/internal/desktop"
)

func installPlatform(owner string) error { return desktop.InstallLinuxService(owner) }
func removePlatform() error              { return desktop.RemoveLinuxService() }
func runPrivilegedStdio(data, core string) error {
	return errors.New("privileged stdio is only supported by the macOS XPC service")
}
