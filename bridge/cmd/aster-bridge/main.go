package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"github.com/Miku0139oao/aster-desktop/bridge/internal/desktop"
	"github.com/sirupsen/logrus"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"syscall"
)

func main() {
	logrus.SetOutput(os.Stderr)
	data := flag.String("data", "", "application data directory")
	core := flag.String("core", "", "bundled core executable")
	gui := flag.String("gui", "", "GUI executable")
	service := flag.Bool("service", false, "run platform service")
	install := flag.Bool("install-service", false, "install platform service")
	remove := flag.Bool("uninstall-service", false, "remove platform service")
	owner := flag.String("owner", "", "service owner")
	privilegedStdio := flag.Bool("privileged-stdio", false, "XPC supervisor transport")
	flag.Parse()
	if *install {
		exit(installPlatform(*owner))
		return
	}
	if *remove {
		exit(removePlatform())
		return
	}
	if *service {
		exit(desktop.RunPlatformService())
		return
	}
	exe, _ := os.Executable()
	if *core == "" {
		name := "aster-core"
		if runtime.GOOS == "windows" {
			name += ".exe"
		}
		*core = filepath.Join(filepath.Dir(exe), name)
	}
	if *data == "" {
		dir, err := os.UserConfigDir()
		if err != nil {
			exit(err)
			return
		}
		*data = filepath.Join(dir, "AsterDesktop")
	}
	if *privilegedStdio {
		exit(runPrivilegedStdio(*data, *core))
		return
	}
	app, err := desktop.NewApp(*data, *core, *gui)
	if err != nil {
		exit(err)
		return
	}
	defer app.Close()
	selection, err := os.ReadFile(filepath.Join(*data, "cores", "selection.json"))
	if err == nil {
		var selected map[string]string
		if json.Unmarshal(selection, &selected) == nil {
			path := selected["active"]
			abs, _ := filepath.Abs(path)
			root, _ := filepath.Abs(filepath.Join(*data, "cores"))
			if filepath.Dir(abs) == root {
				if _, err = os.Stat(abs); err == nil {
					app.Core.Binary = abs
				}
			}
		}
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	go func() { <-ctx.Done(); _ = os.Stdin.Close() }()
	err = desktop.ServeStdio(ctx, app, os.Stdin, os.Stdout)
	_ = app.Close()
	if ctx.Err() == nil {
		exit(err)
	}
}
func exit(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
