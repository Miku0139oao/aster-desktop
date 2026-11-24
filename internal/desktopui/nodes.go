package desktopui

import (
	"bytes"
	"cmp"
	"context"
	"encoding/json"
	"fmt"
	"maps"
	"net/url"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/egoist/mygo/ui"
)

type nodeChoice struct {
	name, provider, protocol string
	delay                    int
}

func (n nodeChoice) key() string {
	var provider any
	if n.provider != "" {
		provider = n.provider
	}
	var out bytes.Buffer
	encoder := json.NewEncoder(&out)
	encoder.SetEscapeHTML(false)
	_ = encoder.Encode([]any{provider, n.name})
	return strings.TrimSuffix(out.String(), "\n")
}

func (a *App) activeNodeGroup(groups []nodeGroup) nodeGroup {
	for _, g := range groups {
		if g.Name == a.nodeGroup {
			return g
		}
	}
	if len(groups) > 0 {
		return groups[0]
	}
	return nodeGroup{}
}

func (a *App) nodes(c *ui.Context) {
	if a.active() == nil {
		a.scrolled(c, func() {
			a.empty(c, a.tr("還沒有可選擇的節點", "No nodes to choose yet"), a.tr("先匯入訂閱；連線後會顯示提供者的完整節點。", "Import a subscription. Provider nodes appear after connecting."))
		})
		return
	}
	if a.objectsOpen {
		a.objects(c)
		return
	}
	groups := a.groups()
	group := a.activeNodeGroup(groups)
	preferenceKey := "browser:" + a.snapshot.State.ActiveID
	browser := object(a.snapshot.State.Preferences[preferenceKey])
	list := browser["list"] == true
	items := a.nodeChoices(group, str(browser["sort"]))
	ui.Column(c).Fill().Padding(4, PagePadding, 20, PagePadding).Gap(12).Children(func() {
		ui.Row(c).Gap(8).Wrap().Children(func() {
			a.search(c, &a.queries[nodes], a.tr("搜尋節點", "Search nodes")).MinWidth(140)
			a.button(c, a.tr("管理節點與群組", "Manage nodes and groups"), false).Disabled(a.busy).OnClick(func() { a.objectsOpen = true })
		})
		if len(groups) > 0 {
			ui.Row(c).Gap(8).Wrap().Children(func() {
				for _, g := range groups {
					b := a.button(c, g.Name, false).AccessSelected(g.Name == group.Name)
					if g.Name == group.Name {
						b.Background(a.palette.selected)
					}
					b.OnClick(func() { a.nodeGroup = g.Name })
				}
			})
			a.nodeControls(c, group, items, list, preferenceKey, browser)
		}
		if len(items) == 0 {
			a.panel(c, func() {
				a.hint(c, a.tr("沒有符合的節點。提供者的節點會在連線後載入。", "No matching nodes. Provider nodes load after connecting."))
			})
			return
		}
		if list {
			ls := &a.lists[nodes]
			ls.Key = func(i int) any { return items[i].key() }
			ui.List(c, ls, len(items), func(i int) { a.nodeCard(c, group, items[i], true) }).Grow(1).Gap(8)
		} else {
			a.nodeGrid.Key = func(i int) any { return items[i].key() }
			ui.GridView(c, &a.nodeGrid, len(items), 208, 100, func(i int) { a.nodeCard(c, group, items[i], false) }).Grow(1).Gap(12)
		}
	})
}
func (a *App) nodeControls(c *ui.Context, group nodeGroup, items []nodeChoice, list bool, key string, browser Object) {
	ui.Row(c).Gap(8).Wrap().Children(func() {
		version := a.tr("列表", "List")
		if list {
			version = a.tr("卡片", "Cards")
		}
		a.button(c, version, false).Disabled(a.busy).OnClick(func() {
			next := maps.Clone(browser)
			next["list"] = !list
			a.preferences(Object{key: next})
		})
		for _, filter := range []struct {
			label string
			value *bool
		}{{a.tr("收藏", "Favorites"), &a.favoritesOnly}, {a.tr("最近選擇", "Recent"), &a.recentOnly}} {
			ui.Toggle(c, filter.value, filter.label).Radius(ControlRadius)
		}
		labels := []string{a.tr("設定順序", "Configuration order"), a.tr("名稱", "Name"), a.tr("延遲", "Latency")}
		values := []string{"configuration", "name", "latency"}
		index := max(0, slices.Index(values, str(browser["sort"])))
		current := labels[index]
		ui.Select(c, &current, labels).Label(a.tr("排序", "Sort by")).Disabled(a.busy).OnChange(func() {
			idx := slices.Index(labels, current)
			if idx >= 0 {
				next := maps.Clone(browser)
				next["sort"] = values[idx]
				a.preferences(Object{key: next})
			}
		})
		if a.measureCancel == nil {
			a.button(c, a.tr("測試延遲", "Test latency"), false).Disabled(!a.running() || a.busy || len(items) == 0).
				OnClick(func() { a.measureNodes(items) })
		} else {
			a.button(c, a.tr("停止測試", "Stop testing"), false).OnClick(func() { a.measureCancel() })
		}
		if group.Now != "" {
			a.button(c, a.tr("重設選擇", "Reset selection"), false).Disabled(a.busy).OnClick(func() {
				running := a.running()
				a.run("forgetSelection", func(ctx context.Context) (func(), error) {
					if running {
						if err := a.api(ctx, "DELETE", "/proxies/"+url.PathEscape(group.Name), nil, nil); err != nil {
							return nil, err
						}
					}
					return a.mutateAfter(ctx, "forgetSelection", Object{"group": group.Name}, nil)
				})
			})
		}
	})
}

func (a *App) nodeChoices(group nodeGroup, sort string) []nodeChoice {
	metadata := make(map[string]nodeChoice)
	record := func(v any, provider string) {
		m := object(v)
		name := str(m["name"])
		if name != "" {
			metadata[name] = nodeChoice{name: name, provider: provider, protocol: str(m["type"])}
		}
	}
	for _, v := range array(a.document()["proxies"]) {
		record(v, "")
	}
	providers := object(a.document()["proxy-providers"])
	for _, provider := range slices.Sorted(maps.Keys(providers)) {
		for _, v := range array(object(providers[provider])["payload"]) {
			record(v, provider)
		}
	}
	for _, provider := range slices.Sorted(maps.Keys(a.providers)) {
		for _, v := range array(object(a.providers[provider])["proxies"]) {
			record(v, provider)
		}
	}
	favorites := stringSlice(a.snapshot.State.Preferences["favorites:"+a.snapshot.State.ActiveID])
	recent := stringSlice(a.snapshot.State.Preferences["recent:"+a.snapshot.State.ActiveID])
	choices := make([]nodeChoice, 0, len(group.All))
	for _, name := range group.All {
		n, ok := metadata[name]
		if !ok {
			n = nodeChoice{name: name, protocol: str(object(a.proxies[name])["type"])}
		}
		n.delay = a.nodeDelays[n.key()]
		if n.delay == 0 {
			history := array(object(a.proxies[name])["history"])
			if len(history) > 0 {
				n.delay = int(number(object(history[len(history)-1])["delay"]))
			}
		}
		if a.favoritesOnly && !slices.Contains(favorites, n.key()) || a.recentOnly && !slices.Contains(recent, name) {
			continue
		}
		if matches(a.queries[nodes], name, n.provider, n.protocol) {
			choices = append(choices, n)
		}
	}
	switch sort {
	case "name":
		slices.SortStableFunc(choices, func(a, b nodeChoice) int { return cmp.Compare(strings.ToLower(a.name), strings.ToLower(b.name)) })
	case "delay", "latency":
		slices.SortStableFunc(choices, func(a, b nodeChoice) int {
			rank := func(delay int) int {
				if delay <= 0 {
					return 1 << 30
				}
				return delay
			}
			return cmp.Compare(rank(a.delay), rank(b.delay))
		})
	}
	return choices
}

func (a *App) nodeCard(c *ui.Context, group nodeGroup, node nodeChoice, list bool) {
	selected := group.Now == node.name
	favoriteKey := "favorites:" + a.snapshot.State.ActiveID
	favorites := stringSlice(a.snapshot.State.Preferences[favoriteKey])
	favorite := slices.Contains(favorites, node.key())
	p := a.palette
	fill := p.panel
	if selected {
		fill = p.selected
	}
	row := ui.Column(c).FillWidth().Radius(16).Background(fill).Padding(10, 12).Gap(4)
	if !list {
		row.FillHeight()
	}
	row.Children(func() {
		ui.Row(c).Gap(4).Children(func() {
			button := ui.ButtonBase(c.Key("select-node")).Grow(1).MinWidth(0).MinHeight(32).Radius(8).Label(node.name).Tooltip(node.name)
			if button.Hovered() {
				button.Background(p.primary.Alpha(.1))
			}
			button.Disabled(a.busy || group.Name == "" || !selectableGroup(group)).AccessSelected(selected).
				Children(func() { ui.Text(c, node.name).FontWeight(600).SingleLine().MinWidth(0).Grow(1) }).
				OnClick(func() { a.selectNode(group.Name, node.name) })
			title := a.tr("收藏", "Favorite")
			if favorite {
				title = a.tr("取消收藏", "Unfavorite")
			}
			b := a.iconButton(c, "star", title).Size(30, 32).Disabled(a.busy)
			if favorite {
				b.TextColor(p.primary).Background(p.primary.Alpha(.15))
			}
			b.OnClick(func() {
				if favorite {
					favorites = slices.DeleteFunc(favorites, func(id string) bool { return id == node.key() })
				} else {
					favorites = append(favorites, node.key())
				}
				a.preferences(Object{favoriteKey: favorites})
			})
		})
		ui.Row(c).Gap(8).Children(func() {
			tags := strings.Trim(strings.Join([]string{node.protocol, node.provider}, " · "), " ·")
			ui.Text(c, tags).TextColor(p.muted).FontSize(11).SingleLine().Grow(1).MinWidth(0)
			delay := "—"
			if node.delay > 0 {
				delay = fmt.Sprintf("%d ms", node.delay)
			} else if node.delay < 0 {
				delay = a.tr("逾時", "Timeout")
			}
			a.button(c, delay, false).Padding(4, 7).Radius(8).FontSize(11).Tooltip(a.tr("測試延遲", "Test latency")).
				Disabled(a.busy || !a.running() || a.measureCancel != nil).OnClick(func() { a.measureNodes([]nodeChoice{node}) })
		})
	})
}
func selectableGroup(g nodeGroup) bool {
	v := strings.ToLower(g.Type)
	return v == "select" || v == "selector" || g.Name == "GLOBAL"
}

func (a *App) measureNodes(nodes []nodeChoice) {
	if !a.running() || a.measureCancel != nil || a.busy || len(nodes) == 0 {
		return
	}
	prefs := a.snapshot.State.Preferences
	timeout := int(number(prefs["testTimeout"]))
	if timeout < 1000 || timeout > 15000 {
		timeout = 5000
	}
	destination := str(prefs["testUrl"])
	if destination == "" {
		destination = "https://www.gstatic.com/generate_204"
	}
	parallel := int(number(prefs["testConcurrency"]))
	if !slices.Contains([]int{1, 2, 4, 8}, parallel) {
		parallel = 4
	}
	ctx, cancel := context.WithCancel(a.ctx)
	a.measureCancel = cancel
	epoch := a.epoch
	results := func() {
		defer cancel()
		for i := 0; i < len(nodes) && ctx.Err() == nil; i += parallel {
			var wg sync.WaitGroup
			delays := make(map[string]int)
			var mu sync.Mutex
			for _, n := range nodes[i:min(i+parallel, len(nodes))] {
				wg.Go(func() {
					path := "/proxies/" + url.PathEscape(n.name) + "/delay"
					if n.provider != "" {
						path = "/providers/proxies/" + url.PathEscape(n.provider) + "/" + url.PathEscape(n.name) + "/healthcheck"
					}
					path += fmt.Sprintf("?timeout=%d&url=%s", timeout, url.QueryEscape(destination))
					request, cancel := context.WithTimeout(ctx, time.Duration(timeout)*time.Millisecond+5*time.Second)
					defer cancel()
					var result Object
					delay := -1
					if a.api(request, "GET", path, nil, &result) == nil && number(result["delay"]) > 0 {
						delay = int(number(result["delay"]))
					}
					mu.Lock()
					delays[n.key()] = delay
					mu.Unlock()
				})
			}
			wg.Wait()
			if ctx.Err() == nil {
				a.dispatch(func() {
					if a.epoch == epoch {
						maps.Copy(a.nodeDelays, delays)
					}
				})
			}
		}
		a.dispatch(func() { a.measureCancel = nil })
	}
	if a.post == nil {
		results()
	} else {
		go results()
	}
}

func (a *App) dispatch(fn func()) {
	if a.post == nil {
		fn()
	} else {
		a.post(fn)
	}
}
func (a *App) objects(c *ui.Context) {
	a.scrolled(c, func() {
		ui.Row(c).Gap(8).Wrap().Children(func() {
			a.button(c, a.tr("回到節點", "Back to nodes"), false).OnClick(func() { a.objectsOpen = false })
			for _, v := range []struct{ key, label string }{{"proxies", a.tr("節點", "Nodes")}, {"proxy-groups", a.tr("群組", "Groups")}, {"proxy-providers", a.tr("節點提供者", "Proxy providers")}, {"rule-providers", a.tr("規則提供者", "Rule providers")}} {
				b := a.button(c, v.label, false).AccessSelected(a.objectsField() == v.key)
				if a.objectsField() == v.key {
					b.Background(a.palette.selected)
				}
				b.OnClick(func() { a.objectKind = v.key })
			}
		})
		field := a.objectsField()
		a.button(c, a.tr("新增", "Add"), true).AlignSelf(ui.Start).Disabled(a.busy).OnClick(func() { a.editObject(field, "", nil) })
		entries := map[string]Object{}
		for _, v := range array(a.document()[field]) {
			o := object(v)
			entries[str(o["name"])] = o
		}
		for k, v := range object(a.document()[field]) {
			entries[k] = object(v)
		}
		if len(entries) == 0 {
			a.panel(c, func() { a.hint(c, a.tr("目前沒有項目。", "No items in this configuration.")) })
		}
		for _, name := range slices.Sorted(maps.Keys(entries)) {
			if strings.HasPrefix(name, "Aster-App-") {
				continue
			}
			a.panel(c.Key(name), func() {
				ui.Row(c).Gap(8).Wrap().Children(func() {
					ui.Text(c, name).Grow(1).SingleLine().Bold().MinWidth(80)
					a.badge(c, str(entries[name]["type"]))
					a.button(c, a.tr("編輯", "Edit"), false).Disabled(a.busy).OnClick(func() { a.editObject(field, name, entries[name]) })
					if a.running() && strings.HasSuffix(field, "providers") {
						which := "proxies"
						if field == "rule-providers" {
							which = "rules"
						}
						a.button(c, a.tr("更新", "Update"), false).Disabled(a.busy).OnClick(func() {
							a.run("controller", func(ctx context.Context) (func(), error) {
								return a.checkRequest(ctx, "PUT", "/providers/"+which+"/"+url.PathEscape(name), nil)
							})
						})
					}
					a.button(c, a.tr("刪除", "Delete"), false).Disabled(a.busy).OnClick(func() {
						a.confirm(a.tr("刪除設定項目？", "Delete this item?"), name, func() {
							a.mutate("manageObject", Object{"id": a.snapshot.State.ActiveID, "field": field, "oldName": name, "action": "delete"}, a.dismiss)
						})
					})
				})
			})
		}
	})
}
func (a *App) objectsField() string {
	if a.objectKind == "" {
		return "proxies"
	}
	return a.objectKind
}
