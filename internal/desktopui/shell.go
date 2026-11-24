package desktopui

import (
	"fmt"
	"runtime"

	"github.com/egoist/mygo/ui"
)

type pageID uint8

const (
	overview pageID = iota
	nodes
	profiles
	applications
	connections
	statistics
	rules
	diagnostics
	logs
	advanced
	pageCount
)

var destinations = [pageCount]struct{ zh, en, icon string }{
	{"首頁", "Overview", "overview"},
	{"節點", "Nodes", "nodes"},
	{"訂閱與設定", "Profiles", "profiles"},
	{"應用程式", "Applications", "apps"},
	{"連線", "Connections", "connections"},
	{"統計", "Statistics", "stats"},
	{"規則", "Rules", "rules"},
	{"診斷", "Diagnostics", "diagnostics"},
	{"日誌", "Logs", "logs"},
	{"進階設定", "Advanced", "settings"},
}

func (a *App) pageName(p pageID) string {
	d := destinations[p]
	return a.tr(d.zh, d.en)
}

func (a *App) View(c *ui.Context) {
	a.theme(c)
	width, _ := c.Size()
	sidebar := SidebarWidth
	if width < 1000 {
		sidebar = CompactSidebarWidth
	}
	mod := ui.Ctrl
	if runtime.GOOS == "darwin" {
		mod = ui.Cmd
	}
	c.OnWindowShortcut(mod, ui.KeyK, a.showJump)
	ui.Row(c).Fill().AlignItems(ui.Stretch).Children(func() {
		a.sidebar(c, sidebar)
		ui.Column(c).Grow(1).MinWidth(0).Children(func() {
			a.header(c)
			if a.errorMessage != "" && !a.dialog.open {
				a.banner(c, a.errorMessage, true)
			} else if a.progress != "" {
				a.banner(c, a.progress, false)
			} else if a.notice != "" {
				a.banner(c, a.notice, false)
			}
			if !a.ready {
				a.startup(c)
				return
			}
			ui.Column(c.Key(a.page)).Grow(1).MinHeight(0).Children(func() {
				switch a.page {
				case overview:
					a.overview(c)
				case nodes:
					a.nodes(c)
				case profiles:
					a.profiles(c)
				case applications:
					a.apps(c)
				case connections:
					a.connectionsPage(c)
				case statistics:
					a.statistics(c)
				case rules:
					a.rules(c)
				case diagnostics:
					a.diagnosticsPage(c)
				case logs:
					a.logsPage(c)
				case advanced:
					a.advanced(c)
				}
			})
		})
	})
	a.showDialog(c)
}

func (a *App) sidebar(c *ui.Context, width float32) {
	p := a.palette
	ui.Column(c).Width(width).Shrink(0).Background(p.panel).Children(func() {
		ui.Row(c).Height(69).Padding(3, 18, 0, 18).Gap(10).Children(func() {
			if mark != nil {
				ui.Image(c, mark).Size(30, 30).Label("Aster")
			}
			ui.Text(c, "Aster").Bold().FontSize(23)
		})
		ui.Scroll(c).Grow(1).MinHeight(0).TrackScroll(&a.navScroll).Role(ui.RoleNavigation).Children(func() {
			for idx, d := range destinations {
				page := pageID(idx)
				section := ""
				switch page {
				case overview:
					section = a.tr("日常使用", "Everyday")
				case connections:
					section = a.tr("活動與分流", "Activity & routing")
				case diagnostics:
					section = a.tr("工具", "Tools")
				}
				if section != "" {
					ui.Text(c, section).FontSize(11).TextColor(p.muted).Padding(10, 12, 6, 24)
				}
				label := a.pageName(page)
				selected := a.page == page
				b := ui.ButtonBase(c.Key(page)).Height(42).Margin(2, 10).Padding(0, 12).Gap(10).
					Radius(12).Justify(ui.Start).AlignItems(ui.Center).Label(label).Tooltip(label).AccessSelected(selected)
				if selected || b.Hovered() {
					b.Background(p.selected)
				}
				b.Children(func() {
					ui.Row(c).TextColor(p.muted).Children(func() { icon(c, d.icon, 19) })
					weight := 500
					if selected {
						weight = 700
					}
					ui.Text(c, label).FontSize(13).FontWeight(weight).SingleLine()
				}).OnClick(func() { a.jump(page) })
			}
		})
		ui.Column(c).Padding(10, 12, 8, 12).Gap(8).AlignItems(ui.Stretch).Children(func() {
			if profile := a.active(); profile != nil {
				ui.Text(c, profile.Name).FontSize(12).TextColor(p.muted).SingleLine().TextAlign(ui.Center)
			}
			label, symbol := a.tr("啟動代理", "Start proxy"), "play"
			if a.running() {
				label, symbol = a.tr("停止代理", "Stop proxy"), "stop"
			}
			disabled := a.busy || a.active() == nil || !a.ready || a.quitting
			background := p.selected
			if disabled {
				background = p.text.Alpha(.17)
			}
			ui.ButtonBase(c.Key("sidebar-connect")).Height(44).Radius(16).Center().Gap(8).Background(background).
				Disabled(disabled).Label(label).Children(func() { icon(c, symbol, 18); ui.Text(c, label).FontSize(14).SingleLine() }).
				OnClick(a.toggle)
			if version := a.snapshot.DesktopVersion; version != "" {
				ui.Text(c, "v"+version).TextColor(p.muted).FontSize(11).TextAlign(ui.Center)
			}
			if a.platform.Quit != nil {
				button := ui.ButtonBase(c.Key("quit")).Height(26).Center().Radius(12)
				if button.Hovered() {
					button.Background(p.selected)
				}
				label := a.tr("退出並停止代理", "Quit and stop proxy")
				button.Label(label).Children(func() { ui.Text(c, label).FontSize(11).TextColor(p.primary).SingleLine() }).OnClick(a.platform.Quit)
			}
		})
	})
}

func (a *App) header(c *ui.Context) {
	ui.Row(c).Height(74).Shrink(0).Padding(6, 23, 0, 24).Gap(6).Children(func() {
		ui.Text(c, a.pageName(a.page)).FontSize(22).Bold().SingleLine().Grow(1).Role(ui.RoleHeading).Level(1)
		a.iconButton(c, "search", a.tr("搜尋頁面", "Find a page")).OnClick(a.showJump)
		name, label := "moon", a.tr("切換至深色模式", "Switch to dark mode")
		if a.nextTheme() == "light" {
			name, label = "sun", a.tr("切換至淺色模式", "Switch to light mode")
		}
		a.iconButton(c, name, label).Disabled(a.busy || !a.ready).OnClick(func() { next := a.settings(); next.Theme = a.nextTheme(); a.saveSettings(next) })
	})
}

func (a *App) banner(c *ui.Context, message string, problem bool) {
	ui.Row(c).Margin(0, PagePadding, 8, PagePadding).Padding(8, 12).Radius(ControlRadius).Gap(8).Background(a.palette.selected).Children(func() {
		text := ui.Text(c, message).Grow(1).MinWidth(0).MaxLines(3)
		if problem {
			text.TextColor(c.Theme().Danger).Role(ui.RoleAlert)
		} else {
			text.Role(ui.RoleStatus)
		}
		a.iconButton(c, "close", a.tr("關閉提示", "Dismiss message")).OnClick(func() { a.errorMessage, a.notice = "", "" })
	})
}

func (a *App) startup(c *ui.Context) {
	ui.Column(c).Grow(1).Center().Padding(32).Gap(12).Children(func() {
		if a.busy {
			ui.Spinner(c)
			a.hint(c, a.tr("正在啟動 Aster Desktop…", "Starting Aster Desktop…"))
			return
		}
		ui.Text(c, a.tr("Aster Desktop 無法啟動", "Aster Desktop could not start")).FontSize(22).Bold()
		a.hint(c, a.tr("請確認已安裝完整套件，或從托盤開啟正在執行的 Aster。", "Check the installation or open the running copy from the tray."))
	})
}

func (a *App) scrolled(c *ui.Context, children func()) {
	ui.Scroll(c).Grow(1).MinHeight(0).TrackScroll(&a.scroll[a.page]).Children(func() {
		ui.Column(c).Padding(4, PagePadding, PagePadding, PagePadding).Gap(16).Children(children)
	})
}

func (a *App) overview(c *ui.Context) {
	a.scrolled(c, func() {
		a.hero(c)
		if a.active() == nil {
			a.firstSteps(c)
		}
		ui.Row(c).Gap(16).AlignItems(ui.Stretch).Children(func() {
			up, down, links := "—", "—", "—"
			var upTotal, downTotal string
			if a.running() {
				up, down, links = formatBytes(a.up)+"/s", formatBytes(a.down)+"/s", fmt.Sprint(len(array(a.connections["connections"])))
				if a.connections != nil {
					upTotal = a.tr("累計上傳", "Total upload") + " " + formatBytes(number(a.connections["uploadTotal"]))
					downTotal = a.tr("累計下載", "Total download") + " " + formatBytes(number(a.connections["downloadTotal"]))
				}
			}
			a.stat(c, "down", a.tr("下載速度", "Download"), down, downTotal)
			a.stat(c, "up", a.tr("上傳速度", "Upload"), up, upTotal)
			a.stat(c, "connections", a.tr("活動連線", "Connections"), links, "")
		})
		a.networkCard(c)
	})
}

func (a *App) hero(c *ui.Context) {
	p := a.palette
	profile := a.active()
	title := a.tr("從一份訂閱開始", "Start with a subscription")
	detail := a.tr("貼上訂閱網址，或匯入已有的設定。", "Paste a subscription URL or import a configuration.")
	label := a.tr("匯入訂閱或設定", "Import a subscription")
	symbol, action := "plus", a.showImport
	if profile != nil {
		title = a.tr("準備好連線", "Ready to connect")
		detail = a.tr("選好節點後，按「開始連線」。", "Choose a node, then connect.")
		label = a.tr("開始連線", "Connect")
		symbol, action = "play", a.toggle
		if a.running() {
			title = a.tr("已連線", "Connected")
			detail = a.tr("你的代理已啟動。", "Your proxy is active.")
			label = a.tr("停止代理", "Disconnect")
			symbol = "stop"
		}
	}
	ui.Column(c).Padding(22).Gap(18).Radius(24).Margin(0, 0, 4, 0).Gradient(p.primaryContainer, p.selected, 100).TextColor(p.onPrimaryContainer).Children(func() {
		ui.Row(c).MinHeight(58).Gap(16).Children(func() {
			ui.Row(c).Size(54, 54).Radius(18).Center().Background(p.background.Alpha(.55)).Children(func() { icon(c, "shield", 30) })
			ui.Column(c).Grow(1).MinWidth(0).Gap(4).Children(func() {
				ui.Text(c, title).FontSize(24).Bold().Role(ui.RoleHeading).Level(2)
				ui.Text(c, detail)
			})
		})
		if profile != nil {
			change := a.tr("目前節點 · 點擊更換", "Current node · Click to change")
			ui.ButtonBase(c.Key("current-node")).Height(64).Padding(0, 16).Gap(12).Radius(16).
				Background(p.background.Alpha(.65)).Label(change).Children(func() {
				icon(c, "nodes", 22)
				ui.Column(c).Grow(1).MinWidth(0).Gap(2).Children(func() {
					ui.Text(c, a.currentNode()).Bold().SingleLine()
					ui.Text(c, change).FontSize(12)
				})
				icon(c, "chevron", 16)
			}).OnClick(func() { a.jump(nodes) })
			ui.ButtonBase(c.Key("current-profile")).AlignSelf(ui.Start).Gap(8).Label(profile.Name).Children(func() {
				icon(c, "profiles", 18)
				ui.Text(c, profile.Name).SingleLine().MaxWidth(360)
			}).OnClick(func() { a.jump(profiles) })
		}
		ui.Row(c).Gap(16).Wrap().Children(func() {
			a.action(c, symbol, label).Disabled(a.busy).OnClick(action)
			if profile != nil {
				label := a.tr("手動代理", "Manual proxy")
				if a.settings().Tun {
					label = a.tr("所有應用程式 · TUN", "All applications · TUN")
				} else if a.settings().SystemProxy {
					label = a.tr("系統代理", "System proxy")
				}
				ui.Text(c, label)
			}
		})
	})
}

func (a *App) firstSteps(c *ui.Context) {
	a.panel(c, func() {
		a.title(c, a.tr("三步開始使用", "Three steps to get connected"))
		ui.Column(c).Gap(16).Margin(8, 0).Children(func() {
			for _, step := range []struct{ icon, title, detail string }{
				{"link", a.tr("1. 匯入", "1. Import"), a.tr("訂閱網址、設定檔或節點分享連結。", "A subscription URL, configuration file, or node links.")},
				{"nodes", a.tr("2. 選擇節點", "2. Choose a node"), a.tr("可以先用自動選擇，之後隨時更換。", "Start with automatic selection and switch whenever you like.")},
				{"check", a.tr("3. 連線", "3. Connect"), a.tr("系統代理會自動設定，不需要終端。", "The system proxy is set up for you. No terminal needed.")},
			} {
				ui.Row(c).MinHeight(48).Gap(18).Children(func() {
					ui.Row(c).TextColor(a.palette.primary).Children(func() { icon(c, step.icon, 24) })
					ui.Column(c).Grow(1).MinWidth(0).Gap(4).Children(func() {
						ui.Text(c, step.title).Bold()
						a.hint(c, step.detail)
					})
				})
			}
		})
	})
}

func (a *App) stat(c *ui.Context, glyph, label, value, caption string) {
	ui.Column(c).Grow(1).Basis(0).MinWidth(0).MinHeight(100).Padding(18, 18, 16, 18).Gap(15).Radius(PanelRadius).Background(a.palette.panel).Children(func() {
		ui.Row(c).Gap(8).Children(func() {
			ui.Row(c).TextColor(a.palette.primary).Children(func() { icon(c, glyph, 16) })
			ui.Text(c, label).FontSize(12).TextColor(a.palette.muted).SingleLine()
		})
		ui.Text(c, value).FontSize(22).Bold().SingleLine()
		if caption != "" {
			ui.Text(c, caption).FontSize(11).TextColor(a.palette.muted).SingleLine()
		}
	})
}

func (a *App) switchRow(c *ui.Context, label, detail string, enabled, disabled bool, change func(bool)) {
	ui.Row(c.Key(label)).MinHeight(56).Gap(12).Children(func() {
		ui.Column(c).Grow(1).MinWidth(0).Gap(3).Children(func() {
			ui.Text(c, label).FontSize(16)
			a.hint(c, detail)
		})
		control := ui.SwitchBase(c, &enabled).Size(52, 32).Margin(0, 4, 0, 0).Radius(16).Label(label).Disabled(disabled)
		track, knob := a.palette.input, a.palette.outline
		if enabled {
			track, knob = a.palette.primary, c.Theme().AccentText
		}
		control.Background(track)
		if !enabled {
			control.Border(2, a.palette.outline)
		}
		control.Children(func() {
			distance, size := 8.0, 16.0
			if enabled {
				distance, size = 24, 24
			}
			ui.Box(c).Size(float32(size), float32(size)).Absolute().Left(float32(distance)).Top(float32((32 - size) / 2)).Radius(16).Background(knob).PassThrough()
		}).OnChange(func() { change(enabled) })
	})
}

func (a *App) networkCard(c *ui.Context) {
	settings := a.settings()
	a.panel(c, func() {
		a.title(c, a.tr("哪些應用程式使用代理？", "Which applications use the proxy?"))
		a.switchRow(c, a.tr("系統代理", "System proxy"), a.tr("讓支援系統代理的應用程式自動連線。", "Connect applications that follow system proxy settings."), settings.SystemProxy, a.busy || a.running(), func(value bool) {
			next := a.settings()
			next.SystemProxy = value
			a.saveSettings(next)
		})
		a.switchRow(c, a.tr("代理所有應用程式", "Proxy all applications"), a.tr("使用 TUN，需要一次性的系統授權。", "Uses TUN and requires system approval once."), settings.Tun, a.busy || a.running(), func(value bool) {
			next := a.settings()
			next.Tun = value
			a.saveSettings(next)
		})
		if settings.Tun {
			a.outboundInterface(c)
			if a.snapshot.Service["installed"] != true || a.snapshot.Service["approved"] == false {
				ui.Row(c).Gap(12).Wrap().Children(func() {
					a.hint(c, a.tr("首次使用需要背景服務授權", "Authorize the background service first"))
					a.button(c, a.tr("安裝／授權", "Authorize"), false).Disabled(a.busy || a.running()).OnClick(func() { a.mutate("installService", nil, nil) })
				})
			}
		}
		ui.Divider(c).Background(a.palette.outline.Alpha(.6))
		a.title(c, a.tr("流量如何選擇出口？", "How should traffic be routed?"))
		ui.Row(c).Gap(8).Wrap().Children(func() {
			for _, mode := range []struct{ id, label string }{{"rule", a.tr("依規則", "Rules")}, {"global", a.tr("全部代理", "Global")}, {"direct", a.tr("全部直連", "Direct")}} {
				btn := a.button(c, mode.label, false).Disabled(a.busy).AccessSelected(settings.Mode == mode.id)
				if settings.Mode == mode.id {
					btn.Background(a.palette.selected)
				}
				btn.OnClick(func() { next := a.settings(); next.Mode = mode.id; a.saveSettings(next) })
			}
		})
	})
}

func (a *App) outboundInterface(c *ui.Context) {
	current := a.settings().TunInterface
	automatic := a.tr("依系統路由", "Follow system routes")
	if current == "" {
		current = automatic
	}
	options := []string{automatic}
	for _, entry := range a.interfaces {
		options = append(options, str(entry["name"]))
	}
	if a.settings().TunInterface != "" && len(a.interfaces) == 0 {
		options = append(options, current)
	}
	ui.Row(c).Gap(8).Wrap().Children(func() {
		label := a.tr("TUN 出站網路", "TUN outbound network")
		ui.Text(c, label)
		ui.Select(c, &current, options).Label(label).Disabled(a.busy || a.running()).OnChange(func() {
			next := a.settings()
			next.TunInterface = current
			if current == automatic {
				next.TunInterface = ""
			}
			a.saveSettings(next)
		})
		a.button(c, a.tr("重新整理網路清單", "Refresh network list"), false).Disabled(a.busy).OnClick(a.loadInterfaces)
	})
}
