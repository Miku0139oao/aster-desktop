// Aster Desktop is the native desktop frontend for the Aster Go bridge.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"runtime"
	"time"

	"github.com/Miku0139oao/aster-desktop/assets"
	"github.com/Miku0139oao/aster-desktop/internal/backend"
	"github.com/Miku0139oao/aster-desktop/internal/desktopui"
	"github.com/Miku0139oao/aster-desktop/internal/instance"
	"github.com/egoist/mygo"
	_ "github.com/egoist/mygo/locales/zh-Hans"
	_ "github.com/egoist/mygo/locales/zh-Hant"
	"github.com/egoist/mygo/ui"
)

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

func run() error {
	data := flag.String("data", "", "application data directory")
	autostart := flag.Bool("autostart", false, "connect using the active configuration at launch")
	flag.Parse()
	if err := desktopui.Setup(); err != nil {
		return fmt.Errorf("register application font: %w", err)
	}
	mygo.App.SetName("Aster Desktop")
	mygo.App.SetLanguages("en", "zh-Hant-TW", "zh-Hans-CN")
	if *data == "" {
		var err error
		*data, err = instance.DataDirectory()
		if err != nil {
			return err
		}
	}
	mygo.App.SetPath(mygo.PathUserData, *data)
	systemLocale := "en"
	if locales := mygo.App.PreferredLanguages(); len(locales) > 0 {
		systemLocale = locales[0]
	}
	activation := make(chan chan bool, 1)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	lease, startErr := instance.Acquire(ctx, *data, func() bool {
		done := make(chan bool, 1)
		select {
		case activation <- done:
		default:
			return false
		}
		select {
		case visible := <-done:
			return visible
		case <-time.After(1500 * time.Millisecond):
			return false
		}
	})
	cancel()
	if lease == nil && startErr == nil {
		return nil
	}
	defer lease.Close()

	var client backend.Client
	if startErr == nil {
		client, startErr = startEngine(*data)
	}
	loop, stopLoop := context.WithCancel(context.Background())
	defer stopLoop()
	var window *mygo.Window
	var model *desktopui.App
	var tray *mygo.Tray
	closing, closed := false, false
	show := func() bool {
		if window != nil && !closing && !window.IsDestroyed() {
			window.Show()
			if window.IsMinimized() {
				window.Restore()
			}
			window.Focus()
			return window.IsVisible()
		}
		return false
	}
	closeEngine := func() {
		if client != nil {
			if err := client.Close(); err != nil {
				log.Printf("shutting down the desktop engine: %v", err)
			}
		}
	}
	stopUI := func() {
		if model != nil {
			model.Stop()
		}
		stopLoop()
	}
	mygo.App.OnActivate(func(visible bool) {
		if !visible {
			show()
		}
	})
	mygo.App.OnBeforeQuit(func(event *mygo.QuitEvent) {
		if closed {
			return
		}
		if event.SessionEnding {
			stopUI()
			closeEngine()
			closed = true
			return
		}
		event.PreventDefault()
		if closing {
			return
		}
		closing = true
		if model == nil {
			closeEngine()
			stopUI()
			closed = true
			mygo.App.Quit()
			return
		}
		window.Update(func() {
			model.RequestQuit(func(err error) {
				if err != nil {
					closing = false
					show()
					return
				}
				stopUI()
				closed = true
				mygo.App.Quit()
			})
		})
	})
	mygo.App.WhenReady(func() {
		if runtime.GOOS == "darwin" {
			mygo.App.SetMenu(mygo.NewMenu([]*mygo.MenuItem{{Role: mygo.RoleAppMenu}, {Role: mygo.RoleEditMenu}}))
		}
		view := desktopui.New(client, func(fn func()) { window.Update(fn) }, desktopui.Platform{
			PickFile: func(title string, extensions []string) (string, error) {
				var filters []mygo.FileFilter
				if len(extensions) > 0 {
					filters = []mygo.FileFilter{{Name: title, Extensions: extensions}}
				}
				paths, err := mygo.Dialog.Open(mygo.OpenDialogOptions{Parent: window, Title: title, Filters: filters})
				if err != nil || len(paths) == 0 {
					return "", err
				}
				return paths[0], nil
			},
			SaveFile: func(title, name string, contents []byte) error {
				path, err := mygo.Dialog.Save(mygo.SaveDialogOptions{Parent: window, Title: title, DefaultPath: name})
				if err != nil || path == "" {
					return err
				}
				return os.WriteFile(path, contents, 0600)
			},
			Copy: mygo.Clipboard.WriteText,
			Quit: mygo.App.Quit,
			Locale: func(value string) {
				mygo.App.SetLocale(map[string]string{"zh_TW": "zh-Hant-TW", "zh_CN": "zh-Hans-CN", "en": "en"}[value])
			},
		}, systemLocale)
		model = view
		window = mygo.NewWindow(mygo.WindowOptions{
			Title: "Aster Desktop", Width: 1180, Height: 800, UseContentSize: true,
			MinWidth: 760, MinHeight: 580, Content: ui.View(view.View),
		})
		if err := window.SetIcon(assets.Icon); err != nil {
			log.Printf("setting the window icon: %v", err)
		}
		if startErr == nil {
			var err error
			tray, err = mygo.NewTray(mygo.TrayOptions{
				Icon: assets.Icon, ToolTip: "Aster Desktop",
				Menu: mygo.NewMenu([]*mygo.MenuItem{
					{Label: "Aster Desktop", Click: func(*mygo.MenuItem, *mygo.Window) { show() }},
					{Label: "連線 / 斷線 · Connect / Disconnect", Click: func(*mygo.MenuItem, *mygo.Window) { window.Update(view.Toggle) }},
					mygo.Separator(),
					{Label: "退出 / Quit", Click: func(*mygo.MenuItem, *mygo.Window) { mygo.App.Quit() }},
				}),
			})
			if err != nil {
				log.Printf("creating the system tray: %v", err)
			} else {
				tray.OnClick(func() { show() })
			}
		}
		window.OnClose(func(event *mygo.CloseEvent) {
			if closed {
				return
			}
			event.PreventDefault()
			if closing {
				return
			}
			if tray != nil {
				window.Hide()
			} else {
				mygo.App.Quit()
			}
		})
		window.OnFocus(func() { window.Update(view.Poll) })
		view.Initialize(*autostart, startErr)
		go view.Listen()
		go func() {
			ticker := time.NewTicker(2 * time.Second)
			defer ticker.Stop()
			for {
				select {
				case <-loop.Done():
					return
				case result := <-activation:
					window.Update(func() { result <- show() })
				case <-ticker.C:
					mygo.RunOnMain(view.Poll)
				}
			}
		}()
	})
	err := mygo.App.Run()
	if !closed {
		closeEngine()
	}
	return err
}

func startEngine(data string) (backend.Client, error) {
	gui, err := os.Executable()
	if err != nil {
		return nil, err
	}
	bridge, core := backend.Executables(gui)
	process, err := backend.Start(bridge, core, data, gui)
	if err != nil {
		return nil, err
	}
	return withPlatformBackend(process, gui), nil
}
