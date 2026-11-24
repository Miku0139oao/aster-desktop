package desktopui

import (
	"cmp"
	"context"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"maps"
	"net/url"
	"slices"
	"strconv"
	"strings"

	"github.com/egoist/mygo/ui"
)

func (a *App) loadInterfaces() {
	a.run("listNetworkInterfaces", func(ctx context.Context) (func(), error) {
		var interfaces []Object
		err := a.client.Call(ctx, "listNetworkInterfaces", nil, &interfaces)
		return func() {
			if err == nil {
				a.interfaces = interfaces
			}
		}, err
	})
}
func (a *App) days() int {
	days := int(number(a.snapshot.State.Preferences["statisticsRange"]))
	if !slices.Contains([]int{1, 7, 30, 365}, days) {
		return 7
	}
	return days
}
func (a *App) loadHistory() {
	days := a.days()
	a.run("trafficHistory", func(ctx context.Context) (func(), error) {
		var result Object
		err := a.client.Call(ctx, "trafficHistory", Object{"days": days}, &result)
		return func() {
			if err == nil {
				a.history = result
			}
		}, err
	})
}
func (a *App) setHistoryRange(days int) {
	prefs := maps.Clone(a.snapshot.State.Preferences)
	if prefs == nil {
		prefs = Object{}
	}
	prefs["statisticsRange"] = days
	a.mutate("preferences", Object{"preferences": prefs}, a.loadHistory)
}

func (a *App) statistics(c *ui.Context) {
	rows := array(a.history["days"])
	var up, down float64
	peak := 1.0
	for _, raw := range rows {
		row := object(raw)
		u, d := number(row["upload"]), number(row["download"])
		up += u
		down += d
		peak = max(peak, u+d)
	}
	a.scrolled(c, func() {
		ui.Row(c).Gap(8).Wrap().Children(func() {
			for _, days := range []int{1, 7, 30, 365} {
				label := fmt.Sprintf(a.tr("最近 %d 天", "Last %d days"), days)
				if days == 1 {
					label = a.tr("今天", "Today")
				}
				btn := a.button(c, label, false).Disabled(a.busy).AccessSelected(days == a.days())
				if days == a.days() {
					btn.Background(a.palette.selected)
				}
				btn.OnClick(func() { a.setHistoryRange(days) })
			}
		})
		ui.Row(c).Gap(16).AlignItems(ui.Stretch).Children(func() {
			a.stat(c, "down", a.tr("下載", "Downloaded"), formatBytes(down), "")
			a.stat(c, "up", a.tr("上傳", "Uploaded"), formatBytes(up), "")
			a.stat(c, "stats", a.tr("總計", "Total"), formatBytes(up+down), "")
		})
		a.panel(c, func() {
			a.title(c, a.tr("每日流量", "Daily traffic"))
			if err := str(a.history["error"]); err != "" {
				a.hint(c, err)
			}
			if len(rows) == 0 {
				a.hint(c, a.tr("尚無流量紀錄。", "No traffic history yet."))
			}
			for _, raw := range slices.Backward(rows) {
				row := object(raw)
				date := str(row["date"])
				u, d := number(row["upload"]), number(row["download"])
				ui.Row(c.Key(date)).Gap(10).Children(func() {
					ui.Text(c, date).Width(100).SingleLine()
					ui.Row(c).Grow(1).Height(8).Background(a.palette.input).Radius(4).Clip().Children(func() {
						ui.Box(c).WidthPercent(float32(d / peak * 100)).FillHeight().Background(a.palette.primary)
						ui.Box(c).WidthPercent(float32(u / peak * 100)).FillHeight().Background(a.palette.onPrimaryContainer.Alpha(.6))
					})
					ui.Text(c, "↓ "+formatBytes(d)+"  ↑ "+formatBytes(u)).Width(145).TextAlign(ui.End).SingleLine().FontSize(12)
				})
			}
		})
		a.breakdown(c, rows, "applications", a.tr("應用程式流量", "Traffic by application"))
		a.breakdown(c, rows, "routes", a.tr("出口流量", "Traffic by route"))
		ui.Row(c).Gap(8).Wrap().Children(func() {
			a.button(c, a.tr("重新整理", "Refresh"), false).Disabled(a.busy).OnClick(a.loadHistory)
			a.button(c, a.tr("匯出 CSV", "Export CSV"), false).Disabled(a.busy || len(rows) == 0 || a.platform.SaveFile == nil).OnClick(func() {
				var buf strings.Builder
				writer := csv.NewWriter(&buf)
				_ = writer.Write([]string{"date", "download_bytes", "upload_bytes"})
				for _, raw := range rows {
					row := object(raw)
					_ = writer.Write([]string{str(row["date"]), fmt.Sprintf("%.0f", number(row["download"])), fmt.Sprintf("%.0f", number(row["upload"]))})
				}
				writer.Flush()
				a.saveFile(a.tr("匯出流量", "Export traffic"), "aster-traffic.csv", []byte(buf.String()))
			})
			a.button(c, a.tr("清除流量紀錄", "Clear traffic history"), false).Disabled(a.busy || len(rows) == 0).OnClick(func() {
				a.confirm(a.tr("清除本機流量紀錄？", "Clear local traffic history?"), "", func() {
					a.mutate("clearTrafficHistory", nil, func() { a.dismiss(); a.loadHistory() })
				})
			})
		})
	})
}
func (a *App) breakdown(c *ui.Context, rows []any, key, title string) {
	type totals struct{ up, down float64 }
	summary := map[string]totals{}
	for _, row := range rows {
		for name, value := range object(object(row)[key]) {
			v := object(value)
			prev := summary[name]
			summary[name] = totals{prev.up + number(v["upload"]), prev.down + number(v["download"])}
		}
	}
	names := slices.Collect(maps.Keys(summary))
	slices.SortFunc(names, func(a, b string) int {
		av, bv := summary[a], summary[b]
		if n := cmp.Compare(bv.up+bv.down, av.up+av.down); n != 0 {
			return n
		}
		return cmp.Compare(a, b)
	})
	a.panel(c, func() {
		a.title(c, title)
		if len(names) == 0 {
			a.hint(c, a.tr("尚無活動連線樣本", "No active-connection samples yet"))
		}
		for _, name := range names[:min(20, len(names))] {
			t := summary[name]
			ui.Row(c.Key(name)).Gap(12).Children(func() {
				ui.Text(c, name).Grow(1).MinWidth(0).SingleLine()
				ui.Text(c, "↓ "+formatBytes(t.down)+"  ↑ "+formatBytes(t.up)).FontSize(12).SingleLine()
			})
		}
	})
}

func (a *App) diagnosticsPage(c *ui.Context) {
	a.scrolled(c, func() {
		a.panel(c, func() {
			a.title(c, a.tr("連線診斷", "Connection diagnostics"))
			a.hint(c, a.tr("分別檢查核心、背景服務、DNS、系統網路與本機代理。", "Check the core, background service, DNS, system network, and local proxy."))
			ui.Row(c).Gap(8).Wrap().Children(func() {
				a.button(c, a.tr("執行診斷", "Run diagnostics"), true).Disabled(a.busy).OnClick(a.diagnose)
				a.button(c, a.tr("匯出診斷", "Export diagnostics"), false).Disabled(a.busy || len(a.diagnostics) == 0 || a.platform.SaveFile == nil).OnClick(func() {
					data, _ := json.MarshalIndent(a.diagnostics, "", "  ")
					a.saveFile(a.tr("匯出診斷", "Export diagnostics"), "aster-diagnostics.txt", []byte(sanitize(string(data))))
				})
			})
			for _, check := range a.diagnostics {
				ui.Row(c.Key(str(check["kind"]))).Gap(10).Padding(6, 0).Children(func() {
					state := str(check["status"])
					a.badge(c, state)
					ui.Column(c).Grow(1).MinWidth(0).Gap(4).Children(func() {
						ui.Text(c, a.diagnosticName(str(check["kind"]))).Bold()
						a.hint(c, str(check["detail"]))
					})
					if ms := number(check["milliseconds"]); ms > 0 {
						ui.Text(c, fmt.Sprintf("%.0f ms", ms)).SingleLine()
					}
				})
			}
		})
		a.panel(c, func() {
			a.title(c, a.tr("DNS 查詢", "DNS lookup"))
			a.hint(c, a.tr("連線後可透過核心查詢 DNS，或清除 DNS 快取。", "Connect to query DNS through the core or flush its DNS cache."))
			if a.dnsType == "" {
				a.dnsType = "A"
			}
			ui.Row(c).Wrap().Gap(8).Children(func() {
				a.field(c, a.tr("網域名稱", "Domain name"), &a.dnsName).Grow(1).MinWidth(160).OnSubmit(a.lookupDNS)
				ui.Select(c, &a.dnsType, []string{"A", "AAAA", "CNAME", "MX", "TXT", "NS", "SOA", "PTR", "HTTPS", "SVCB"}).Label(a.tr("記錄類型", "Record type"))
				a.button(c, a.tr("查詢", "Look up"), false).Disabled(a.busy || !a.running()).OnClick(a.lookupDNS)
				a.button(c, a.tr("清除 DNS 快取", "Flush DNS cache"), false).Disabled(a.busy || !a.running()).OnClick(func() {
					a.run("controller", func(ctx context.Context) (func(), error) {
						err := a.api(ctx, "POST", "/cache/dns/flush", nil, nil)
						return func() {
							if err == nil {
								a.notice = a.tr("DNS 快取已清除。", "DNS cache cleared.")
							}
						}, err
					})
				})
			})
			if a.dnsResult != nil {
				data, _ := json.MarshalIndent(a.dnsResult, "", "  ")
				result := string(data)
				ui.TextArea(c, &result).ReadOnly(true).Height(230).Label(a.tr("DNS 查詢結果", "DNS lookup result"))
			}
		})
	})
}
func (a *App) diagnosticName(key string) string {
	switch key {
	case "core":
		return a.tr("核心", "Core")
	case "service":
		return a.tr("背景服務", "Background service")
	case "network":
		return a.tr("網路介面", "Network interfaces")
	case "dns":
		return a.tr("系統 DNS", "System DNS")
	case "systemRequest":
		return a.tr("系統網路", "System request")
	case "proxyRequest":
		return a.tr("本機代理", "Proxy request")
	default:
		return key
	}
}
func (a *App) diagnose() {
	a.run("diagnose", func(ctx context.Context) (func(), error) {
		var checks []Object
		err := a.client.Call(ctx, "diagnose", nil, &checks)
		return func() {
			if err == nil {
				a.diagnostics = checks
			}
		}, err
	})
}
func (a *App) lookupDNS() {
	if !a.running() || strings.TrimSpace(a.dnsName) == "" {
		return
	}
	path := "/dns/query?name=" + url.QueryEscape(strings.TrimSpace(a.dnsName)) + "&type=" + url.QueryEscape(a.dnsType)
	a.run("controller", func(ctx context.Context) (func(), error) {
		var result Object
		err := a.api(ctx, "GET", path, nil, &result)
		return func() {
			if err == nil {
				a.dnsResult = result
			}
		}, err
	})
}

func (a *App) settingChoice(c *ui.Context, label, value string, keys, labels []string, change func(string)) {
	ui.Column(c).Gap(6).Children(func() {
		ui.Text(c, label)
		current := labels[max(0, slices.Index(keys, value))]
		ui.Select(c, &current, labels).Label(label).Disabled(a.busy).OnChange(func() {
			if i := slices.Index(labels, current); i >= 0 {
				change(keys[i])
			}
		})
	})
}
func (a *App) advanced(c *ui.Context) {
	settings := a.settings()
	a.scrolled(c, func() {
		a.panel(c, func() {
			a.title(c, a.tr("外觀與一般設定", "Appearance and general"))
			a.settingChoice(c, a.tr("介面語言", "Language"), settings.Language, []string{"system", "zh_TW", "zh_CN", "en"}, []string{a.tr("跟隨系統", "Follow system"), "繁體中文", "简体中文", "English"}, func(value string) {
				next := a.settings()
				next.Language = value
				a.saveSettings(next)
			})
			a.settingChoice(c, a.tr("外觀", "Appearance"), settings.Theme, []string{"system", "light", "dark"}, []string{a.tr("跟隨系統", "System"), a.tr("淺色", "Light"), a.tr("深色", "Dark")}, func(value string) {
				next := a.settings()
				next.Theme = value
				a.saveSettings(next)
			})
			a.switchRow(c, a.tr("登入後自動啟動並連線", "Start and connect at login"), a.tr("使用目前選擇的設定。", "Uses the selected configuration."), settings.AutoStart, a.busy, func(value bool) {
				next := a.settings()
				next.AutoStart = value
				a.saveSettings(next)
			})
			intervals := []string{"0", "1", "6", "24", "168"}
			labels := []string{a.tr("僅手動更新", "Manual only")}
			for _, value := range intervals[1:] {
				labels = append(labels, fmt.Sprintf(a.tr("每 %s 小時", "Every %s hours"), value))
			}
			if saved := strconv.Itoa(settings.SubscriptionHours); !slices.Contains(intervals, saved) {
				intervals = append(intervals, saved)
				labels = append(labels, fmt.Sprintf(a.tr("每 %s 小時", "Every %s hours"), saved))
			}
			a.settingChoice(c, a.tr("自動更新訂閱", "Refresh subscriptions"), strconv.Itoa(settings.SubscriptionHours), intervals, labels, func(value string) {
				next := a.settings()
				next.SubscriptionHours, _ = strconv.Atoi(value)
				a.saveSettings(next)
			})
		})
		a.servicePanel(c)
		a.panel(c, func() {
			a.title(c, a.tr("網路與分流", "Network and routing"))
			a.switchRow(c, a.tr("允許區域網路使用代理", "Allow LAN access"), a.tr("讓其他裝置使用這台電腦的代理連接埠。", "Allow other devices to use this computer’s proxy port."), settings.AllowLAN, a.busy, func(value bool) {
				next := a.settings()
				next.AllowLAN = value
				a.saveSettings(next)
			})
			ui.Row(c).Gap(10).Wrap().Children(func() {
				a.hint(c, fmt.Sprintf("%s  ·  127.0.0.1:%d", a.tr("本機代理連接埠", "Local proxy port"), settings.MixedPort))
				a.button(c, a.tr("修改連接埠", "Change port"), false).Disabled(a.busy || a.running()).OnClick(func() {
					a.dialog = dialog{open: true, kind: portDialog, input: strconv.Itoa(settings.MixedPort)}
				})
			})
			p := a.active()
			ui.Row(c).Gap(8).Wrap().Children(func() {
				for _, action := range []struct {
					label string
					fn    func()
				}{
					{a.tr("DNS 設定", "DNS settings"), a.editDNS},
					{a.tr("新增分流規則", "Add routing rule"), func() { a.openRule("DOMAIN", "", "") }},
					{a.tr("應用程式分流", "Application routing"), func() { a.jump(applications) }},
					{a.tr("編輯完整 YAML", "Edit full YAML"), func() {
						if p != nil {
							a.openYAML(*p)
						}
					}},
				} {
					a.button(c, action.label, false).Disabled(a.busy || p == nil).OnClick(action.fn)
				}
				a.button(c, a.tr("延遲測試設定", "Latency test settings"), false).Disabled(a.busy).OnClick(a.openLatencySettings)
			})
		})
		a.panel(c, func() {
			a.title(c, a.tr("版本與更新", "Versions and updates"))
			a.hint(c, "Aster Desktop "+a.snapshot.DesktopVersion)
			if version := a.snapshot.Core.Version; version != "" {
				a.hint(c, "Aster Core "+version)
			}
			ui.Row(c).Gap(12).Wrap().Children(func() {
				a.button(c, a.tr("檢查更新", "Check for updates"), false).Disabled(a.busy).OnClick(a.checkUpdates)
				ui.Link(c, a.tr("使用說明", "User guide"), "https://astercore.fubukishop.app/")
			})
		})
	})
}
func (a *App) servicePanel(c *ui.Context) {
	installed, approved := a.snapshot.Service["installed"] == true, a.snapshot.Service["approved"] != false
	a.panel(c, func() {
		a.title(c, a.tr("背景服務", "Background service"))
		detail := a.tr("安裝後可使用 TUN，主介面維持一般權限。", "Install to use TUN while keeping the interface unprivileged.")
		if installed && approved {
			detail = a.tr("已安裝；代理所有應用程式時會使用。", "Installed. Used when proxying all applications.")
		}
		if installed && !approved {
			detail = a.tr("請在系統設定中完成授權。", "Approve the service in System Settings.")
		}
		a.hint(c, detail)
		ui.Row(c).Gap(8).Wrap().Children(func() {
			label := a.tr("安裝背景服務", "Install service")
			if installed {
				label = a.tr("重新安裝／授權", "Reinstall / authorize")
			}
			a.button(c, label, true).Disabled(a.busy || a.running()).OnClick(func() { a.mutate("installService", nil, nil) })
			if installed {
				a.button(c, a.tr("移除服務", "Remove service"), false).Disabled(a.busy || a.running()).OnClick(func() {
					a.confirm(a.tr("移除背景服務？", "Remove the background service?"), "", func() { a.mutate("uninstallService", nil, a.dismiss) })
				})
			}
		})
	})
}
func (a *App) portForm(c *ui.Context) {
	a.dialogTitle(c, a.tr("本機代理連接埠", "Local proxy port"))
	a.field(c, a.tr("連接埠", "Port"), &a.dialog.input).AutoFocus()
	a.dialogButtons(c, a.tr("儲存", "Save"), func() {
		port, err := strconv.Atoi(strings.TrimSpace(a.dialog.input))
		if err != nil || port < 1024 || port > 65535 {
			a.dialog.err = a.tr("請輸入 1024 至 65535。", "Enter a port from 1024 to 65535.")
			return
		}
		next := a.settings()
		next.MixedPort = port
		a.mutate("settings", next, a.dismiss)
	})
}
func (a *App) editDNS() {
	dns := object(a.document()["dns"])
	mode := str(dns["enhanced-mode"])
	if mode == "" {
		mode = "fake-ip"
	}
	enabled := "off"
	if dns["enable"] == true {
		enabled = "on"
	}
	a.dialog = dialog{open: true, kind: dnsDialog, id: a.snapshot.State.ActiveID, choice: mode, name: enabled,
		source: strings.Join(stringSlice(dns["nameserver"]), "\n"), input: strings.Join(stringSlice(dns["fallback"]), "\n")}
}
func (a *App) dnsForm(c *ui.Context) {
	d := &a.dialog
	a.dialogTitle(c, a.tr("DNS 設定", "DNS settings"))
	enabled := d.name == "on"
	ui.Checkbox(c, &enabled, a.tr("啟用 DNS", "Enable DNS")).Disabled(a.busy).OnChange(func() {
		if enabled {
			d.name = "on"
		} else {
			d.name = "off"
		}
	})
	ui.Select(c, &d.choice, []string{"fake-ip", "redir-host"}).Label(a.tr("DNS 模式", "DNS mode")).Disabled(a.busy)
	ui.TextArea(c, &d.source).Height(68).Label(a.tr("DNS 伺服器", "Name servers")).Placeholder(a.tr("DNS 伺服器，每行一個", "Name servers, one per line")).Disabled(a.busy)
	ui.TextArea(c, &d.input).Height(68).Label(a.tr("備用 DNS", "Fallback DNS")).Placeholder(a.tr("備用 DNS，每行一個", "Fallback DNS, one per line")).Disabled(a.busy)
	a.dialogButtons(c, a.tr("儲存", "Save"), func() {
		dns := Object{"enable": d.name == "on", "enhanced-mode": d.choice, "nameserver": strings.Fields(d.source), "fallback": strings.Fields(d.input)}
		a.mutate("patchProfile", Object{"id": d.id, "changes": Object{"dns": dns}}, a.dismiss)
	})
}
func (a *App) openLatencySettings() {
	prefs := a.snapshot.State.Preferences
	address := str(prefs["testUrl"])
	if address == "" {
		address = "https://www.gstatic.com/generate_204"
	}
	timeout := int(number(prefs["testTimeout"]))
	if timeout == 0 {
		timeout = 5000
	}
	parallel := int(number(prefs["testConcurrency"]))
	if parallel == 0 {
		parallel = 4
	}
	a.dialog = dialog{open: true, kind: testDialog, source: address, input: strconv.Itoa(timeout), choice: strconv.Itoa(parallel)}
}
func (a *App) latencyForm(c *ui.Context) {
	d := &a.dialog
	a.dialogTitle(c, a.tr("延遲測試設定", "Latency test settings"))
	a.field(c, a.tr("測試網址", "Test URL"), &d.source)
	a.field(c, a.tr("逾時（毫秒）", "Timeout (ms)"), &d.input)
	ui.Select(c, &d.choice, []string{"1", "2", "4", "8"}).Label(a.tr("同時測試數", "Concurrent tests")).Disabled(a.busy)
	a.dialogButtons(c, a.tr("儲存", "Save"), func() {
		address, err := url.Parse(strings.TrimSpace(d.source))
		timeout, timeoutErr := strconv.Atoi(d.input)
		if err != nil || address.Host == "" || (address.Scheme != "https" && address.Scheme != "http") || timeoutErr != nil || timeout < 1000 || timeout > 15000 {
			d.err = a.tr("請輸入 HTTP／HTTPS 網址及 1000 至 15000 毫秒。", "Enter an HTTP/HTTPS URL and a timeout of 1000 to 15000 ms.")
			return
		}
		parallel, _ := strconv.Atoi(d.choice)
		next := maps.Clone(a.snapshot.State.Preferences)
		if next == nil {
			next = Object{}
		}
		next["testUrl"], next["testTimeout"], next["testConcurrency"] = address.String(), timeout, parallel
		a.mutate("preferences", Object{"preferences": next}, a.dismiss)
	})
}
func (a *App) checkUpdates() {
	a.run("checkUpdates", func(ctx context.Context) (func(), error) {
		var data Object
		err := a.client.Call(ctx, "checkUpdates", nil, &data)
		return func() {
			if err == nil {
				a.dialog = dialog{open: true, kind: updateDialog, data: data}
			}
		}, err
	})
}
func (a *App) updateForm(c *ui.Context) {
	a.dialogTitle(c, a.tr("版本與更新", "Versions and updates"))
	a.hint(c, "Aster Core "+str(object(a.dialog.data["core"])["tag_name"]))
	if latest := str(object(a.dialog.data["gui"])["tag_name"]); latest != "" {
		a.hint(c, "Aster Desktop "+latest)
		ui.Link(c, a.tr("下載桌面版", "Download Aster Desktop"), "https://github.com/Miku0139oao/aster-desktop/releases")
	}
	a.dialogButtons(c, a.tr("更新核心", "Update core"), func() {
		a.mutate("updateCore", nil, func() { a.dismiss(); a.notice = a.tr("核心已更新。", "Core updated.") })
	})
}
