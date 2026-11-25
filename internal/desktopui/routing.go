package desktopui

import (
	"context"
	"encoding/base64"
	"fmt"
	"maps"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/egoist/mygo/ui"
)

type ruleRow struct {
	raw, kind, match, target string
	disabled                 bool
}

func (a *App) ruleRows() []ruleRow {
	p := a.active()
	if p == nil {
		return nil
	}
	active := stringSlice(a.document()["rules"])
	seen := map[string]bool{}
	order := append(slices.Clone(p.RuleOrder), active...)
	order = append(order, p.DisabledRules...)
	rows := make([]ruleRow, 0, len(order))
	activeSet, disabled := map[string]bool{}, map[string]bool{}
	for _, rule := range active {
		activeSet[rule] = true
	}
	for _, rule := range p.DisabledRules {
		disabled[rule] = true
	}
	for _, rule := range order {
		if seen[rule] || (!disabled[rule] && !activeSet[rule]) {
			continue
		}
		seen[rule] = true
		parts := strings.Split(rule, ",")
		last := len(parts) - 1
		if last > 0 && slices.Contains([]string{"no-resolve", "src"}, parts[last]) {
			last--
		}
		if last == 0 {
			continue
		}
		rows = append(rows, ruleRow{rule, parts[0], strings.Join(parts[1:last], ","), parts[last], disabled[rule]})
	}
	return rows
}

func (a *App) rules(c *ui.Context) {
	if a.active() == nil {
		a.scrolled(c, func() {
			a.empty(c, a.tr("還沒有分流規則", "No routing rules yet"), a.tr("先匯入一份設定。", "Import a configuration to manage its rules."))
		})
		return
	}
	all := a.ruleRows()
	results := slices.DeleteFunc(slices.Clone(all), func(r ruleRow) bool {
		return !matches(a.queries[rules], r.raw) || (a.ruleFilter == "enabled" && r.disabled) || (a.ruleFilter == "disabled" && !r.disabled)
	})
	ui.Column(c).Fill().Padding(4, PagePadding, 20, PagePadding).Gap(12).Children(func() {
		ui.Row(c).Gap(8).Wrap().Children(func() {
			a.search(c, &a.queries[rules], a.tr("搜尋規則", "Search rules")).MinWidth(160)
			a.button(c, a.tr("建立分流規則", "Create routing rule"), true).Disabled(a.busy).OnClick(func() { a.openRule("DOMAIN", "", "") })
			a.button(c, a.tr("編輯 YAML", "Edit YAML"), false).Disabled(a.busy).OnClick(func() { a.openYAML(*a.active()) })
		})
		ui.Row(c).Gap(8).Wrap().Children(func() {
			for _, filter := range []struct{ value, label string }{{"", a.tr("全部", "All")}, {"enabled", a.tr("啟用", "Enabled")}, {"disabled", a.tr("停用", "Disabled")}} {
				b := a.button(c, filter.label, false).AccessSelected(a.ruleFilter == filter.value)
				if a.ruleFilter == filter.value {
					b.Background(a.palette.selected)
				}
				b.OnClick(func() { a.ruleFilter = filter.value })
			}
			ui.Spacer(c)
			a.hint(c, fmt.Sprintf(a.tr("%d 條規則", "%d rules"), len(results)))
		})
		if len(results) == 0 {
			a.panel(c, func() { a.hint(c, a.tr("沒有符合的規則。", "No matching rules.")) })
			return
		}
		state := &a.lists[rules]
		state.Key = func(i int) any { return results[i].raw }
		ui.List(c, state, len(results), func(i int) { a.ruleItem(c, results[i], all) }).Grow(1).Gap(8)
	})
}
func (a *App) ruleItem(c *ui.Context, r ruleRow, all []ruleRow) {
	id := a.snapshot.State.ActiveID
	ui.Row(c).Radius(14).Background(a.palette.panel).Padding(10, 12).Gap(8).Children(func() {
		ui.Column(c).Grow(1).MinWidth(0).Gap(4).Children(func() {
			ui.Text(c, r.match).SingleLine().Bold().Tooltip(r.raw)
			ui.Text(c, r.kind+" · "+a.routeName(r)).TextColor(a.palette.muted).FontSize(12).SingleLine()
		})
		verb, label := "disable", a.tr("停用", "Disable")
		if r.disabled {
			verb, label = "enable", a.tr("啟用", "Enable")
		}
		a.button(c, label, false).Padding(8, 12).Disabled(a.busy).OnClick(func() {
			a.mutate("manageRules", Object{"id": id, "action": verb, "rule": r.raw}, nil)
		})
		for _, move := range []struct {
			step        int
			icon, label string
		}{{-1, "up", a.tr("上移規則", "Move rule up")}, {1, "down", a.tr("下移規則", "Move rule down")}} {
			idx := slices.IndexFunc(all, func(v ruleRow) bool { return v.raw == r.raw })
			dest := idx + move.step
			a.iconButton(c, move.icon, move.label).Size(30, 36).Disabled(a.busy || dest < 0 || dest >= len(all)).OnClick(func() {
				order := make([]string, len(all))
				for i, row := range all {
					order[i] = row.raw
				}
				order[idx], order[dest] = order[dest], order[idx]
				a.mutate("manageRules", Object{"id": id, "action": "order", "order": order}, nil)
			})
		}
		a.iconButton(c, "close", a.tr("刪除規則", "Delete rule")).Size(30, 36).Disabled(a.busy || r.disabled).OnClick(func() {
			a.confirm(a.tr("刪除這條規則？", "Delete this rule?"), r.raw, func() { a.mutate("patchProfile", Object{"id": id, "removeRule": r.raw}, a.dismiss) })
		})
	})
}

func (a *App) routeName(r ruleRow) string {
	if p := a.active(); p != nil {
		for _, route := range p.ProviderRoutes {
			if route.Group == r.target {
				return route.Provider + " · " + route.Node
			}
		}
	}
	return r.target
}

func (a *App) openRule(kind, match, previous string) {
	a.dialog = dialog{open: true, kind: ruleDialog, id: a.snapshot.State.ActiveID, choice: kind, input: match, source: previous, name: "DIRECT"}
}
func (a *App) ruleForm(c *ui.Context) {
	d := &a.dialog
	a.dialogTitle(c, a.tr("建立分流規則", "Create routing rule"))
	kinds := []string{"DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "IP-CIDR", "IP-CIDR6", "PROCESS-NAME", "PROCESS-PATH", "RULE-SET", "GEOIP", "GEOSITE"}
	ui.Select(c, &d.choice, kinds).Label(a.tr("比對條件", "Match type")).Disabled(a.busy)
	a.field(c, a.tr("比對內容", "Match value"), &d.input).AutoFocus()
	a.routePicker(c)
	a.dialogButtons(c, a.tr("儲存規則", "Save rule"), func() {
		match := strings.TrimSpace(d.input)
		if match == "" || strings.ContainsAny(match, ",\r\n") {
			d.err = a.tr("請輸入不含逗號的比對內容。", "Enter a match value without commas.")
			return
		}
		payload := Object{"id": d.id}
		if d.source != "" {
			payload["removeRule"] = d.source
		}
		if provider, node, ok := a.chosenProvider(d.name); ok {
			payload["providerRoute"] = Object{"kind": d.choice, "match": match, "provider": provider, "node": node}
		} else {
			payload["rule"] = strings.Join([]string{d.choice, match, d.name}, ",")
		}
		a.mutate("patchProfile", payload, a.dismiss)
	})
}
func (a *App) routePicker(c *ui.Context) {
	choices := a.targets()
	for _, provider := range slices.Sorted(maps.Keys(a.providers)) {
		for _, entry := range array(object(a.providers[provider])["proxies"]) {
			if name := str(object(entry)["name"]); name != "" {
				choices = append(choices, provider+" · "+name)
			}
		}
	}
	label := a.tr("流量出口", "Route target")
	ui.Text(c, label)
	ui.Combobox(c, &a.dialog.name, choices).Label(label).Disabled(a.busy)
}
func (a *App) chosenProvider(choice string) (provider, node string, ok bool) {
	for name, raw := range a.providers {
		for _, entry := range array(object(raw)["proxies"]) {
			n := str(object(entry)["name"])
			if choice == name+" · "+n {
				return name, n, true
			}
		}
	}
	return "", "", false
}
func (a *App) loadApplications() {
	if a.applicationsLoading || a.quitting || a.client == nil {
		return
	}
	a.applicationsLoading, a.applicationsError = true, nil
	apps := []Object{}
	a.readList("listApplications", 30*time.Second, &apps, func(err error) {
		a.applicationsLoading, a.applicationsError = false, err
		if err == nil {
			if apps == nil {
				apps = []Object{}
			}
			a.applications = apps
			clear(a.appIcons)
		}
	})
}
func (a *App) apps(c *ui.Context) {
	if a.active() == nil {
		a.scrolled(c, func() {
			a.empty(c, a.tr("先匯入一份設定", "Import a configuration first"), a.tr("應用程式的分流規則會儲存在使用中的設定。", "Application routes are saved in the active configuration."))
		})
		return
	}
	routes := map[string]ruleRow{}
	for _, rule := range a.ruleRows() {
		if rule.kind == "PROCESS-PATH" {
			routes[rule.match] = rule
		}
	}
	apps := slices.Clone(a.applications)
	known := map[string]bool{}
	for _, app := range apps {
		known[str(app["path"])] = true
	}
	for path := range routes {
		if !known[path] {
			apps = append(apps, Object{"path": path, "name": filepath.Base(path)})
		}
	}
	apps = slices.DeleteFunc(apps, func(app Object) bool {
		path := str(app["path"])
		return !matches(a.queries[applications], str(app["name"]), path, a.routeName(routes[path])) ||
			(a.appFilter == "running" && app["running"] != true) ||
			(a.appFilter == "routed" && routes[path].raw == "")
	})
	ui.Column(c).Fill().Padding(4, PagePadding, 20, PagePadding).Gap(12).Children(func() {
		a.hint(c, a.tr("使用 TUN +「依規則」讓應用程式走你指定的出口。", "Use TUN and Rules mode to route applications through the selected target."))
		if a.applicationsLoading {
			ui.Text(c, a.tr("正在讀取應用程式…", "Loading applications…")).TextColor(a.palette.muted).Role(ui.RoleStatus)
		} else if a.applicationsError != nil {
			message := a.tr("無法讀取應用程式清單。", "Could not load applications.") + " " + a.applicationsError.Error()
			ui.Text(c, message).MaxLines(3).TextColor(c.Theme().Danger).Role(ui.RoleAlert)
		}
		ui.Row(c).Gap(8).Wrap().Children(func() {
			a.search(c, &a.queries[applications], a.tr("搜尋應用程式", "Search applications")).MinWidth(170)
			a.button(c, a.tr("重新整理", "Refresh"), false).Disabled(a.applicationsLoading).OnClick(a.loadApplications)
			a.button(c, a.tr("選擇執行檔", "Choose executable"), false).Disabled(a.busy || a.platform.PickFile == nil).OnClick(a.pickExecutable)
		})
		ui.Row(c).Gap(8).Wrap().Children(func() {
			for _, filter := range []struct{ value, label string }{{"", a.tr("全部", "All")}, {"running", a.tr("執行中", "Running")}, {"routed", a.tr("已有規則", "With rules")}} {
				b := a.button(c, filter.label, false).AccessSelected(a.appFilter == filter.value)
				if a.appFilter == filter.value {
					b.Background(a.palette.selected)
				}
				b.OnClick(func() { a.appFilter = filter.value })
			}
			ui.Spacer(c)
			if len(a.selectedApps) > 0 {
				a.button(c, fmt.Sprintf(a.tr("指定出口 (%d)", "Set route (%d)"), len(a.selectedApps)), true).Disabled(a.busy).OnClick(func() {
					a.dialog = dialog{open: true, kind: routeDialog, id: a.snapshot.State.ActiveID, name: "DIRECT"}
				})
			}
		})
		if len(apps) == 0 {
			if !a.applicationsLoading && a.applicationsError == nil {
				a.panel(c, func() { a.hint(c, a.tr("沒有符合的應用程式。", "No matching applications.")) })
			}
			return
		}
		ls := &a.lists[applications]
		ls.Key = func(i int) any { return str(apps[i]["path"]) }
		ui.List(c, ls, len(apps), func(i int) {
			path := str(apps[i]["path"])
			a.applicationRow(c, apps[i], routes[path])
		}).Grow(1).Gap(8)
	})
}
func (a *App) applicationRow(c *ui.Context, app Object, rule ruleRow) {
	path, name := str(app["path"]), str(app["name"])
	checked := a.selectedApps[path]
	ui.Row(c).Padding(10, 12).Gap(10).Radius(14).Background(a.palette.panel).Children(func() {
		ui.Checkbox(c, &checked, "").Label(name).Disabled(a.busy).OnChange(func() {
			if checked {
				a.selectedApps[path] = true
			} else {
				delete(a.selectedApps, path)
			}
		})
		a.applicationIcon(c, path, name, str(app["icon"]))
		ui.Column(c).Grow(1).MinWidth(0).Gap(4).Children(func() {
			ui.Text(c, name).Bold().SingleLine()
			ui.Text(c, path).FontSize(11).TextColor(a.palette.muted).SingleLine().Tooltip(path)
		})
		if rule.raw != "" {
			a.badge(c, a.routeName(rule))
		}
		a.button(c, a.tr("指定出口", "Set route"), false).Padding(8, 12).Disabled(a.busy).OnClick(func() {
			a.dialog = dialog{open: true, kind: routeDialog, id: a.snapshot.State.ActiveID, name: "DIRECT", source: path}
			if rule.target != "" {
				a.dialog.name = a.routeName(rule)
			}
		})
		if rule.raw != "" && !rule.disabled {
			a.iconButton(c, "close", a.tr("移除分流", "Remove route")).Size(30, 36).Disabled(a.busy).OnClick(func() {
				a.confirm(a.tr("移除應用程式分流？", "Remove application route?"), name, func() {
					a.mutate("patchProfile", Object{"id": a.snapshot.State.ActiveID, "removeRule": rule.raw}, a.dismiss)
				})
			})
		}
	})
}
func (a *App) applicationIcon(c *ui.Context, path, name, encoded string) {
	if encoded != "" && len(encoded) < 45000 {
		img, ok := a.appIcons[path]
		if !ok {
			raw, _ := base64.StdEncoding.DecodeString(encoded)
			img, _ = ui.DecodeBitmap(raw)
			a.appIcons[path] = img
		}
		if img != nil {
			ui.Image(c, img).Size(32, 32)
			return
		}
	}
	var initial string
	for _, ch := range name {
		initial = strings.ToUpper(string(ch))
		break
	}
	ui.Row(c).Size(32, 32).Center().Radius(16).Background(a.palette.selected).Children(func() { ui.Text(c, initial).Bold() })
}
func (a *App) pickExecutable() {
	title, id := a.tr("選擇執行檔", "Choose executable"), a.snapshot.State.ActiveID
	a.run("file", func(context.Context) (func(), error) {
		path, err := a.platform.PickFile(title, nil)
		return func() {
			if path != "" {
				a.dialog = dialog{open: true, kind: routeDialog, id: id, name: "DIRECT", source: path}
			}
		}, err
	})
}
func (a *App) routeForm(c *ui.Context) {
	d := &a.dialog
	a.dialogTitle(c, a.tr("指定應用程式出口", "Choose an application route"))
	paths := slices.Sorted(maps.Keys(a.selectedApps))
	if d.source != "" {
		paths = []string{d.source}
		a.hint(c, filepath.Base(d.source))
	} else {
		a.hint(c, fmt.Sprintf(a.tr("已選擇 %d 個應用程式", "%d selected applications"), len(paths)))
	}
	a.routePicker(c)
	a.dialogButtons(c, a.tr("套用", "Apply"), func() {
		payload := Object{"id": d.id, "paths": paths}
		if provider, node, ok := a.chosenProvider(d.name); ok {
			payload["providerRoute"] = Object{"provider": provider, "node": node}
		} else if slices.Contains(a.targets(), d.name) {
			payload["target"] = d.name
		} else {
			d.err = a.tr("請選擇流量出口。", "Choose a route target.")
			return
		}
		a.mutate("batchApplicationRules", payload, func() {
			if d.source == "" {
				clear(a.selectedApps)
			}
			a.dismiss()
		})
	})
}
