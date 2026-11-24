package desktopui

import (
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

type Object = map[string]any

type Settings struct {
	Language          string `json:"language"`
	Theme             string `json:"theme"`
	SystemProxy       bool   `json:"systemProxy"`
	Tun               bool   `json:"tun"`
	TunInterface      string `json:"tunInterface"`
	AllowLAN          bool   `json:"allowLan"`
	MixedPort         int    `json:"mixedPort"`
	Mode              string `json:"mode"`
	AutoStart         bool   `json:"autoStart"`
	SubscriptionHours int    `json:"subscriptionHours"`
}

func defaultSettings() Settings {
	return Settings{Language: "system", Theme: "system", SystemProxy: true, MixedPort: 7890, Mode: "rule", SubscriptionHours: 24}
}

type Profile struct {
	ID             string                                                `json:"id"`
	Name           string                                                `json:"name"`
	URL            string                                                `json:"url"`
	Content        string                                                `json:"content"`
	Updated        time.Time                                             `json:"updated"`
	LastAttempt    time.Time                                             `json:"lastAttempt"`
	Warnings       []string                                              `json:"warnings"`
	Usage          string                                                `json:"usage"`
	LastError      string                                                `json:"lastError"`
	IntervalHours  *int                                                  `json:"intervalHours"`
	DisabledRules  []string                                              `json:"disabledRules"`
	RuleOrder      []string                                              `json:"ruleOrder"`
	ProviderRoutes []struct{ Kind, Match, Provider, Node, Group string } `json:"desktopProviderRoutes"`
}
type State struct {
	Settings    Settings          `json:"settings"`
	Profiles    []Profile         `json:"profiles"`
	ActiveID    string            `json:"activeId"`
	Selections  map[string]string `json:"selections"`
	Preferences Object            `json:"preferences"`
}
type Snapshot struct {
	State State `json:"state"`
	Core  struct {
		Running bool   `json:"running"`
		Error   string `json:"error"`
		Version string `json:"version"`
	} `json:"core"`
	Service        Object `json:"service"`
	DesktopVersion string `json:"desktopVersion"`
}
type nodeGroup struct {
	Name, Type, Now string
	All             []string
}

func (a *App) active() *Profile {
	for i := range a.snapshot.State.Profiles {
		p := &a.snapshot.State.Profiles[i]
		if p.ID == a.snapshot.State.ActiveID {
			return p
		}
	}
	return nil
}
func (a *App) document() Object {
	p := a.active()
	if p == nil {
		return Object{}
	}
	if a.parsedContent != p.Content || a.parsed == nil {
		a.parsed = parseDocument(p.Content)
		a.parsedContent = p.Content
	}
	return a.parsed
}

func parseDocument(content string) Object {
	document := Object{}
	_ = yaml.Unmarshal([]byte(content), &document)
	return document
}

func profileTarget(document Object) string {
	for _, v := range slices.Backward(array(document["rules"])) {
		parts := strings.Split(str(v), ",")
		if len(parts) > 1 && (parts[0] == "MATCH" || parts[0] == "FINAL") {
			return strings.TrimSpace(parts[1])
		}
	}
	for _, entry := range array(document["proxy-groups"]) {
		g := object(entry)
		if g["type"] == "select" {
			return str(g["name"])
		}
	}
	return "DIRECT"
}
func (a *App) groups() []nodeGroup {
	groups := []nodeGroup{}
	for _, v := range array(a.document()["proxy-groups"]) {
		g := object(v)
		name := str(g["name"])
		if strings.HasPrefix(name, "Aster-App-") {
			continue
		}
		live := object(a.proxies[name])
		all := stringSlice(live["all"])
		if len(all) == 0 {
			all = stringSlice(g["proxies"])
			for _, provider := range stringSlice(g["use"]) {
				for _, entry := range array(object(object(a.document()["proxy-providers"])[provider])["payload"]) {
					if n := str(object(entry)["name"]); n != "" && !slices.Contains(all, n) {
						all = append(all, n)
					}
				}
			}
		}
		now := str(live["now"])
		if now == "" {
			now = a.snapshot.State.Selections[name]
		}
		if now == "" && len(all) > 0 {
			now = all[0]
		}
		groups = append(groups, nodeGroup{name, str(g["type"]), now, all})
	}
	if global := object(a.proxies["GLOBAL"]); len(array(global["all"])) > 0 {
		groups = append(groups, nodeGroup{"GLOBAL", str(global["type"]), str(global["now"]), stringSlice(global["all"])})
	}
	return groups
}
func (a *App) currentNode() string {
	if a.settings().Mode == "direct" {
		return "DIRECT"
	}
	target := profileTarget(a.document())
	gs := a.groups()
	if a.settings().Mode == "global" && (a.running() || a.snapshot.State.Selections["GLOBAL"] != "") {
		target = "GLOBAL"
	}
	seen := map[string]bool{}
	for !seen[target] {
		seen[target] = true
		next := str(object(a.proxies[target])["now"])
		if next == "" {
			next = a.snapshot.State.Selections[target]
		}
		if next == "" {
			for _, g := range gs {
				if g.Name == target {
					next = g.Now
					break
				}
			}
		}
		if next == "" {
			break
		}
		target = next
	}
	return target
}
func (a *App) targets() []string {
	r := []string{"DIRECT", "REJECT"}
	for _, g := range a.groups() {
		r = append(r, g.Name)
	}
	for _, v := range array(a.document()["proxies"]) {
		name := str(object(v)["name"])
		if name != "" {
			r = append(r, name)
		}
	}
	return r
}
func (a *App) settings() Settings { return a.snapshot.State.Settings }
func object(v any) Object {
	m, _ := v.(map[string]any)
	if m == nil {
		return Object{}
	}
	return m
}
func array(v any) []any { x, _ := v.([]any); return x }
func str(v any) string {
	if v == nil {
		return ""
	}
	s, _ := v.(string)
	if s != "" {
		return s
	}
	return fmt.Sprint(v)
}
func number(v any) float64 {
	switch n := v.(type) {
	case float64:
		return n
	case int:
		return float64(n)
	case uint64:
		return float64(n)
	case json.Number:
		f, _ := n.Float64()
		return f
	}
	return 0
}
func stringSlice(v any) []string {
	if ss, ok := v.([]string); ok {
		return slices.Clone(ss)
	}
	out := []string{}
	for _, s := range array(v) {
		out = append(out, str(s))
	}
	return out
}
func formatBytes(n float64) string {
	units := []string{"B", "KB", "MB", "GB", "TB"}
	i := 0
	for n >= 1024 && i < len(units)-1 {
		n /= 1024
		i++
	}
	if i == 0 {
		return fmt.Sprintf("%.0f %s", n, units[i])
	}
	return fmt.Sprintf("%.1f %s", n, units[i])
}
func matches(query string, values ...string) bool {
	return strings.Contains(strings.ToLower(strings.Join(values, " ")), strings.ToLower(strings.TrimSpace(query)))
}
