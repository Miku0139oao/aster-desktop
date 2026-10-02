package main

import (
	"context"
	"errors"
	"github.com/Miku0139oao/aster-desktop/bridge/internal/desktop"
	"os"
	"path/filepath"
)

func installPlatform(owner string) error {
	return errors.New("install through SMAppService in the GUI")
}
func removePlatform() error { return errors.New("remove through SMAppService in the GUI") }
func runPrivilegedStdio(data, core string) error {
	if os.Geteuid() != 0 {
		return errors.New("XPC supervisor must be privileged")
	}
	c := desktop.NewServiceCore(core, filepath.Join(data, "runtime"))
	defer c.Stop()
	return desktop.ServePrivilegedStdio(context.Background(), c, os.Stdin, os.Stdout)
}
