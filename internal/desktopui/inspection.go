package desktopui

import (
	"cmp"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"regexp"
	"slices"
	"strings"

	"github.com/egoist/mygo/ui"
)

type connection struct {
	id, host, ip, port, network, app, path, route, rule, started string
	down, up                                                     float64
	raw                                                          Object
}

func connectionFrom(raw Object) connection {
	m := object(raw["metadata"])
	address := str(m["host"])
	if address == "" {
		address = str(m["destinationIP"])
	}
	return connection{
		id: str(raw["id"]), host: address, ip: str(m["destinationIP"]), port: str(m["destinationPort"]),
		network: str(m["network"]), app: str(m["process"]), path: str(m["processPath"]),
		route: strings.Join(stringSlice(raw["chains"]), " → "), rule: strings.TrimSpace(str(raw["rule"]) + " " + str(raw["rulePayload"])),
		started: str(raw["start"]), up: number(raw["upload"]), down: number(raw["download"]), raw: raw,
	}
}
func (a *App) connectionsPage(c *ui.Context) {
	rows := make([]connection, 0)
	for _, raw := range array(a.connections["connections"]) {
		link := connectionFrom(object(raw))
		if a.connectionFilter != "" && !strings.EqualFold(a.connectionFilter, link.network) {
			continue
		}
		if inspectionMatches(a.queries[connections], []string{link.host, link.ip, link.port, link.app, link.path, link.route, link.rule, link.network},
			map[string]string{"host": link.host, "ip": link.ip, "port": link.port, "app": link.app + " " + link.path, "route": link.route, "rule": link.rule, "network": link.network}) {
			rows = append(rows, link)
		}
	}
	switch a.sortConnections {
	case "up":
		slices.SortStableFunc(rows, func(a, b connection) int { return cmp.Compare(b.up, a.up) })
	case "down":
		slices.SortStableFunc(rows, func(a, b connection) int { return cmp.Compare(b.down, a.down) })
	default:
		slices.SortStableFunc(rows, func(a, b connection) int { return cmp.Compare(b.started, a.started) })
	}
	ui.Column(c).Fill().Padding(4, PagePadding, 20, PagePadding).Gap(12).Children(func() {
		ui.Row(c).Gap(8).Wrap().Children(func() {
			a.search(c, &a.queries[connections], a.tr("搜尋主機、應用程式或規則", "Search hosts, applications or rules")).MinWidth(180)
			a.pauseButton(c, &a.pausedConnections)
			a.button(c, a.tr("中止所有連線", "Close all connections"), false).Disabled(a.busy || !a.running()).OnClick(func() {
				a.confirm(a.tr("中止所有活動連線？", "Close all active connections?"), "", func() {
					a.closeConnection("")
				})
			})
		})
		ui.Row(c).Gap(8).Wrap().Children(func() {
			all := a.tr("所有協定", "All protocols")
			current := a.connectionFilter
			if current == "" {
				current = all
			}
			ui.Select(c, &current, []string{all, "TCP", "UDP"}).Label(a.tr("協定", "Protocol")).OnChange(func() {
				if current == all {
					current = ""
				}
				a.connectionFilter = current
			})
			a.sortChoice(c, a.tr("排序", "Sort by"), &a.sortConnections, []string{"", "down", "up"}, []string{a.tr("最新連線", "Most recent"), a.tr("下載量", "Downloaded"), a.tr("上傳量", "Uploaded")})
			ui.Spacer(c)
			a.hint(c, fmt.Sprintf("%d  ·  ↓ %s  ↑ %s", len(rows), formatBytes(number(a.connections["downloadTotal"])), formatBytes(number(a.connections["uploadTotal"]))))
		})
		if len(rows) == 0 {
			a.panel(c, func() {
				if !a.running() {
					a.hint(c, a.tr("啟動代理後會在這裡顯示連線。", "Connections appear here after the proxy starts."))
				} else {
					a.hint(c, a.tr("沒有符合的連線。", "No matching connections."))
				}
			})
			return
		}
		ls := &a.lists[connections]
		ls.Key = func(i int) any { return rows[i].id }
		ui.List(c, ls, len(rows), func(i int) { a.connectionRow(c, rows[i]) }).Grow(1).Gap(8)
	})
}
func (a *App) sortChoice(c *ui.Context, label string, value *string, keys, labels []string) {
	current := labels[max(0, slices.Index(keys, *value))]
	ui.Select(c, &current, labels).Label(label).OnChange(func() {
		if i := slices.Index(labels, current); i >= 0 {
			*value = keys[i]
		}
	})
}
func (a *App) pauseButton(c *ui.Context, paused *bool) {
	label := a.tr("暫停", "Pause")
	if *paused {
		label = a.tr("繼續", "Resume")
	}
	a.button(c, label, false).OnClick(func() {
		*paused = !*paused
		if !*paused {
			a.Poll()
		}
	})
}
func (a *App) connectionRow(c *ui.Context, link connection) {
	ui.Row(c).Gap(10).Padding(10, 12).Radius(14).Background(a.palette.panel).Children(func() {
		text := link.host
		if link.port != "" {
			text = net.JoinHostPort(link.host, link.port)
		}
		button := ui.ButtonBase(c).Grow(1).MinWidth(0).Label(text).Radius(8)
		if button.Hovered() {
			button.Background(a.palette.selected)
		}
		button.Children(func() {
			ui.Column(c).Grow(1).MinWidth(0).Gap(4).Children(func() {
				ui.Text(c, text).Bold().SingleLine()
				ui.Text(c, strings.Join([]string{link.app, link.route, link.rule}, "  ")).FontSize(12).TextColor(a.palette.muted).SingleLine()
			})
		}).OnClick(func() { a.dialog = dialog{kind: connectionDialog, open: true, data: link.raw} })
		a.badge(c, strings.ToUpper(link.network))
		ui.Text(c, "↓ "+formatBytes(link.down)+"  ↑ "+formatBytes(link.up)).FontSize(12).SingleLine()
		a.iconButton(c, "close", a.tr("中止連線", "Close connection")).Size(32, 36).Disabled(a.busy || !a.running()).OnClick(func() { a.closeConnection(link.id) })
	})
}
func (a *App) closeConnection(id string) {
	// The broker accepts /connections/ for closing all connections.
	path := "/connections/" + url.PathEscape(id)
	a.run("controller", func(ctx context.Context) (func(), error) {
		if err := a.api(ctx, "DELETE", path, nil, nil); err != nil {
			return nil, err
		}
		return func() { a.dismiss(); a.Poll() }, nil
	})
}
func (a *App) connectionDetail(c *ui.Context) {
	link := connectionFrom(a.dialog.data)
	a.dialogTitle(c, a.tr("連線詳情", "Connection details"))
	fields := [][2]string{
		{a.tr("目的地", "Destination"), link.host}, {a.tr("目的地 IP", "Destination IP"), link.ip},
		{a.tr("連接埠", "Port"), link.port}, {a.tr("通訊協定", "Protocol"), link.network},
		{a.tr("應用程式", "Application"), link.app}, {a.tr("執行檔路徑", "Executable path"), link.path},
		{a.tr("流量出口", "Route"), link.route}, {a.tr("規則", "Rule"), link.rule},
		{a.tr("連線時間", "Started"), link.started}, {a.tr("累計流量", "Total traffic"), "↓ " + formatBytes(link.down) + "  ↑ " + formatBytes(link.up)},
	}
	ui.Scroll(c).MaxHeight(310).Shrink(1).Children(func() {
		for _, field := range fields {
			if field[1] != "" {
				ui.Row(c).Padding(5, 0).Gap(12).Children(func() {
					ui.Text(c, field[0]).Width(118).TextColor(a.palette.muted)
					ui.Text(c, field[1]).Grow(1).MinWidth(0).Selectable()
				})
			}
		}
	})
	ui.Row(c).Gap(8).Wrap().Justify(ui.End).Children(func() {
		a.button(c, a.tr("複製詳情", "Copy details"), false).Disabled(a.platform.Copy == nil).OnClick(func() {
			raw, _ := json.MarshalIndent(link.raw, "", "  ")
			a.copyText(string(raw))
		})
		a.button(c, a.tr("建立分流規則", "Create rule"), false).Disabled(a.active() == nil || a.busy).OnClick(func() {
			kind, match := "DOMAIN", link.host
			if link.path != "" {
				kind, match = "PROCESS-PATH", link.path
			} else if link.host == link.ip {
				kind, match = "IP-CIDR", link.ip+"/32"
				if strings.Contains(link.ip, ":") {
					kind, match = "IP-CIDR6", link.ip+"/128"
				}
			}
			a.openRule(kind, match, "")
		})
		a.button(c, a.tr("中止連線", "Close connection"), false).Disabled(a.busy || !a.running()).OnClick(func() { a.closeConnection(link.id) })
		a.button(c, a.tr("完成", "Done"), true).Disabled(a.busy).OnClick(a.dismiss)
	})
}

func inspectionMatches(query string, values []string, fields map[string]string) bool {
	for _, word := range strings.Fields(query) {
		key, value, paired := strings.Cut(word, ":")
		if field, exists := fields[strings.ToLower(key)]; paired && exists {
			if !matches(value, field) {
				return false
			}
		} else if !matches(word, values...) {
			return false
		}
	}
	return true
}

var (
	nodeLink     = regexp.MustCompile(`(?i)(?:ss|vmess|vless|trojan|hy2|hysteria2|tuic|anytls)://\S+`)
	bearer       = regexp.MustCompile(`(?i)Bearer\s+\S+`)
	credential   = regexp.MustCompile(`(?i)(password|secret|token|private-key)[=:]\s*[^\s,;]+`)
	consoleColor = regexp.MustCompile("\\x1B\\[[0-9;]*m")
	levelPattern = regexp.MustCompile(`(?i)(?:\blevel\s*=\s*"?|\[)(trace|debug|info|warn(?:ing)?|error|fatal|panic)\b`)
	timePattern  = regexp.MustCompile(`\btime=(?:"([^"]+)"|(\S+))`)
)

func sanitize(s string) string {
	return credential.ReplaceAllString(bearer.ReplaceAllString(nodeLink.ReplaceAllString(s, "[node link redacted]"), "Bearer [redacted]"), "${1}=[redacted]")
}
func (a *App) copyText(text string) {
	if a.platform.Copy != nil {
		a.platform.Copy(sanitize(text))
		a.notice = a.tr("已複製", "Copied")
	}
}

type logEntry struct{ level, source, time, message, raw string }

func parseLog(value string) logEntry {
	raw := consoleColor.ReplaceAllString(value, "")
	var data Object
	_ = json.Unmarshal([]byte(raw), &data)
	level := str(data["level"])
	if level == "" {
		level = str(data["type"])
	}
	if level == "" {
		if match := levelPattern.FindStringSubmatch(raw); len(match) > 1 {
			level = match[1]
		}
	}
	level = strings.ToLower(level)
	switch level {
	case "warn":
		level = "warning"
	case "fatal", "panic":
		level = "error"
	case "trace":
		level = "debug"
	case "":
		level = "info"
	}
	source := "core"
	if strings.HasPrefix(raw, "Desktop:") || strings.HasPrefix(raw, "Core rollback:") {
		source = "desktop"
	}
	timestamp := str(data["time"])
	if timestamp == "" {
		timestamp = str(data["timestamp"])
	}
	if timestamp == "" {
		if m := timePattern.FindStringSubmatch(raw); len(m) == 3 {
			timestamp = m[1] + m[2]
		}
	}
	message := str(data["msg"])
	if message == "" {
		message = str(data["message"])
	}
	if message == "" {
		message = str(data["payload"])
	}
	if message == "" {
		if _, msg, ok := strings.Cut(raw, "msg="); ok {
			message = strings.Trim(msg, "\"")
		} else {
			message = raw
		}
	}
	return logEntry{level, source, timestamp, message, raw}
}
func (a *App) logsPage(c *ui.Context) {
	var entries []logEntry
	for _, line := range slices.Backward(a.logs) {
		entry := parseLog(line)
		if len(a.logLevels) > 0 && !a.logLevels[entry.level] || a.logSource != "" && a.logSource != entry.source {
			continue
		}
		if inspectionMatches(a.queries[logs], []string{entry.raw}, map[string]string{"level": entry.level, "source": entry.source, "message": entry.message}) {
			entries = append(entries, entry)
		}
	}
	ui.Column(c).Fill().Padding(4, PagePadding, 20, PagePadding).Gap(12).Children(func() {
		ui.Row(c).Gap(8).Wrap().Children(func() {
			a.search(c, &a.queries[logs], a.tr("搜尋日誌", "Search logs")).MinWidth(150)
			a.pauseButton(c, &a.pausedLogs)
			a.button(c, a.tr("匯出篩選日誌", "Export filtered logs"), false).Disabled(a.busy || len(entries) == 0 || a.platform.SaveFile == nil).OnClick(func() {
				var b strings.Builder
				for _, entry := range slices.Backward(entries) {
					b.WriteString(sanitize(entry.raw))
					b.WriteByte('\n')
				}
				a.saveFile(a.tr("匯出日誌", "Export logs"), "aster-logs.txt", []byte(b.String()))
			})
		})
		ui.Row(c).Gap(8).Wrap().Children(func() {
			for _, level := range []string{"debug", "info", "warning", "error"} {
				on := a.logLevels[level]
				ui.Toggle(c.Key(level), &on, level).Radius(ControlRadius).OnChange(func() {
					if on {
						a.logLevels[level] = true
					} else {
						delete(a.logLevels, level)
					}
				})
			}
			a.sortChoice(c, a.tr("來源", "Source"), &a.logSource, []string{"", "core", "desktop"}, []string{a.tr("所有來源", "All sources"), a.tr("核心", "Core"), a.tr("桌面", "Desktop")})
		})
		if len(entries) == 0 {
			a.panel(c, func() { a.hint(c, a.tr("沒有符合的日誌。", "No matching logs.")) })
			return
		}
		ui.List(c, nil, len(entries), func(i int) {
			entry := entries[i]
			b := ui.ButtonBase(c).Padding(10, 12).Gap(10).Radius(14).Background(a.palette.panel).Label(entry.message)
			if b.Hovered() {
				b.Background(a.palette.selected)
			}
			b.Children(func() {
				a.badge(c, entry.level)
				ui.Text(c, entry.source).TextColor(a.palette.muted).FontSize(12).Width(50)
				ui.Text(c, entry.message).SingleLine().MinWidth(0).Grow(1)
			}).OnClick(func() { a.pausedLogs = true; a.dialog = dialog{open: true, kind: logDialog, source: entry.raw} })
		}).Grow(1).Gap(6)
	})
}
func (a *App) logDetail(c *ui.Context) {
	entry := parseLog(a.dialog.source)
	a.dialogTitle(c, a.tr("日誌詳情", "Log details"))
	ui.Row(c).Gap(8).Wrap().Children(func() { a.badge(c, entry.level); a.badge(c, entry.source); a.hint(c, entry.time) })
	ui.TextArea(c, &entry.raw).ReadOnly(true).MaxHeight(260).Height(170).Label(a.tr("原始日誌", "Raw log"))
	ui.Row(c).Gap(8).Justify(ui.End).Children(func() {
		a.button(c, a.tr("複製這筆", "Copy entry"), false).Disabled(a.platform.Copy == nil).OnClick(func() { a.copyText(entry.raw); a.dialog.notice = a.tr("已複製", "Copied") })
		a.button(c, a.tr("完成", "Done"), true).OnClick(a.dismiss)
	})
	a.dialogFeedback(c)
}
