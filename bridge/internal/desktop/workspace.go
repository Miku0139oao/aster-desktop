package desktop

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"gopkg.in/yaml.v3"
	"net/url"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

type SubscriptionPreview struct {
	ID                     string   `json:"id"`
	Token                  string   `json:"token"`
	Added                  []string `json:"added"`
	Removed                []string `json:"removed"`
	Changed                []string `json:"changed"`
	Warnings               []string `json:"warnings"`
	content, usage, before string
	expires                time.Time
}

func cloneProfile(p Profile) Profile {
	b, _ := json.Marshal(p)
	var copy Profile
	_ = json.Unmarshal(b, &copy)
	return copy
}

// Follow explicit YAML edits for objects already owned by the desktop, so a
// later subscription refresh cannot resurrect their previous GUI values.
func reconcileWorkspace(content string, p *Profile) error {
	var doc map[string]any
	if err := yaml.Unmarshal([]byte(content), &doc); err != nil {
		return err
	}
	if p.DesktopRemoved == nil {
		p.DesktopRemoved = map[string][]string{}
	}
	for field, overrides := range p.DesktopObjects {
		objects := map[string]map[string]any{}
		if strings.HasSuffix(field, "providers") {
			for name, raw := range mapValue(doc[field]) {
				if obj, ok := raw.(map[string]any); ok {
					objects[name] = obj
				}
			}
		} else {
			rows, _ := doc[field].([]any)
			for _, raw := range rows {
				if obj, ok := raw.(map[string]any); ok {
					if name, ok := obj["name"].(string); ok {
						objects[name] = obj
					}
				}
			}
		}
		for name := range overrides {
			if obj, ok := objects[name]; ok {
				overrides[name] = obj
			} else {
				delete(overrides, name)
				if p.DesktopRemoved == nil {
					p.DesktopRemoved = map[string][]string{}
				}
				if !slices.Contains(p.DesktopRemoved[field], name) {
					p.DesktopRemoved[field] = append(p.DesktopRemoved[field], name)
				}
			}
		}
		p.DesktopRemoved[field] = slices.DeleteFunc(p.DesktopRemoved[field], func(name string) bool { _, ok := objects[name]; return ok })
	}
	var followSettings func(map[string]any, map[string]any)
	followSettings = func(owned, edited map[string]any) {
		for key := range owned {
			value, exists := edited[key]
			if !exists {
				delete(owned, key)
				continue
			}
			if nested, ok := owned[key].(map[string]any); ok {
				if changed, ok := value.(map[string]any); ok {
					followSettings(nested, changed)
					continue
				}
			}
			owned[key] = value
		}
	}
	followSettings(p.DesktopSettings, doc)
	rules, _ := doc["rules"].([]any)
	p.DisabledRules = slices.DeleteFunc(p.DisabledRules, func(rule string) bool { return slices.Contains(rules, any(rule)) })
	if len(p.RuleOrder) > 0 {
		p.RuleOrder = nil
		for _, raw := range rules {
			if rule, ok := raw.(string); ok {
				p.RuleOrder = append(p.RuleOrder, rule)
			}
		}
		p.RuleOrder = append(p.RuleOrder, p.DisabledRules...)
	}
	return nil
}

func mapValue(value any) map[string]any { result, _ := value.(map[string]any); return result }

func withDisabledRules(content string, disabled []string) string {
	if len(disabled) == 0 {
		return content
	}
	var doc map[string]any
	if yaml.Unmarshal([]byte(content), &doc) != nil {
		return content
	}
	rules, _ := doc["rules"].([]any)
	for _, rule := range disabled {
		rules = append(rules, rule)
	}
	doc["rules"] = rules
	b, _ := yaml.Marshal(doc)
	return string(b)
}

// Desktop overlays survive remote refreshes. Core validation remains the
// authority for references and protocol options; no controller settings enter here.
func mergeWorkspace(content string, p Profile) (string, error) {
	var doc map[string]any
	if err := yaml.Unmarshal([]byte(content), &doc); err != nil {
		return "", err
	}
	if doc == nil {
		return "", errors.New("configuration must be a mapping")
	}
	mergeConfig(doc, p.DesktopSettings)
	for _, field := range []string{"proxies", "proxy-groups", "proxy-providers", "rule-providers"} {
		overrides := p.DesktopObjects[field]
		removed := p.DesktopRemoved[field]
		if len(overrides) == 0 && len(removed) == 0 {
			continue
		}
		if strings.HasSuffix(field, "providers") {
			objects, _ := doc[field].(map[string]any)
			if objects == nil {
				objects = map[string]any{}
			}
			for _, name := range removed {
				delete(objects, name)
			}
			for name, obj := range overrides {
				objects[name] = obj
			}
			doc[field] = objects
		} else {
			objects, _ := doc[field].([]any)
			next := []any{}
			seen := map[string]bool{}
			for _, raw := range objects {
				obj, _ := raw.(map[string]any)
				name, _ := obj["name"].(string)
				if slices.Contains(removed, name) {
					continue
				}
				if override, ok := overrides[name]; ok {
					obj = override
				}
				next = append(next, obj)
				seen[name] = true
			}
			names := []string{}
			for name := range overrides {
				names = append(names, name)
			}
			slices.Sort(names)
			for _, name := range names {
				if !seen[name] {
					next = append(next, overrides[name])
				}
			}
			doc[field] = next
		}
	}
	if len(p.DisabledRules) > 0 || len(p.RuleOrder) > 0 {
		rules, _ := doc["rules"].([]any)
		next := []any{}
		seen := map[string]bool{}
		for _, rule := range p.RuleOrder {
			if slices.Contains(rules, any(rule)) && !slices.Contains(p.DisabledRules, rule) && !seen[rule] {
				next = append(next, rule)
				seen[rule] = true
			}
		}
		for _, raw := range rules {
			rule, _ := raw.(string)
			if !seen[rule] && !slices.Contains(p.DisabledRules, rule) {
				// Newly downloaded rules must remain reachable after a saved
				// custom order; appending them after MATCH would hide them.
				at := slices.IndexFunc(next, func(value any) bool {
					text, _ := value.(string)
					return strings.HasPrefix(strings.ToUpper(strings.TrimSpace(text)), "MATCH,")
				})
				if at < 0 {
					next = append(next, raw)
				} else {
					next = slices.Insert(next, at, raw)
				}
				seen[rule] = true
			}
		}
		doc["rules"] = next
	}
	b, err := yaml.Marshal(doc)
	return string(b), err
}

func (a *App) commitProfile(ctx context.Context, previous *Profile, next Profile) error {
	if _, err := a.Core.Validate(ctx, next.Content, a.Store.State.Settings, false); err != nil {
		return err
	}
	old := cloneProfile(*previous)
	active := a.Store.State.ActiveID == next.ID
	if active {
		if err := a.apply(ctx, next.Content, a.Store.State.Settings); err != nil {
			return err
		}
	}
	backup, _ := json.Marshal(old)
	if err := AtomicWrite(a.Store.Dir+"/backup-"+safeName(old.ID)+".json", backup, 0600); err != nil {
		if active {
			_ = a.apply(ctx, old.Content, a.Store.State.Settings)
		}
		return err
	}
	*previous = next
	if err := a.Store.Save(); err != nil {
		*previous = old
		if active {
			_ = a.apply(ctx, old.Content, a.Store.State.Settings)
		}
		return err
	}
	return nil
}

func profileStamp(p Profile) string {
	b, _ := json.Marshal(p)
	return fmt.Sprintf("%x", sha256.Sum256(b))
}

func objectInventory(content string) map[string]string {
	var doc map[string]any
	_ = yaml.Unmarshal([]byte(content), &doc)
	inventory := map[string]string{}
	for _, field := range []string{"proxies", "proxy-groups", "proxy-providers", "rule-providers"} {
		if objects, ok := doc[field].([]any); ok {
			for _, raw := range objects {
				obj, _ := raw.(map[string]any)
				name, _ := obj["name"].(string)
				b, _ := json.Marshal(obj)
				inventory[field+" / "+name] = string(b)
			}
		}
		if objects, ok := doc[field].(map[string]any); ok {
			for name, obj := range objects {
				b, _ := json.Marshal(obj)
				inventory[field+" / "+name] = string(b)
			}
		}
	}
	rules, _ := json.Marshal(doc["rules"])
	inventory["rules"] = string(rules)
	dns, _ := json.Marshal(doc["dns"])
	inventory["dns"] = string(dns)
	return inventory
}

// Called with the application mutex held. Previews are bounded, expire, and
// are checked against the complete profile before committing downloaded data.
func (a *App) workspace(ctx context.Context, req Request) (any, error) {
	var q struct {
		ID, Name, URL, Token, Field, OldName, Rule, Action string
		IntervalHours                                      *int
		Object                                             map[string]any
		Preferences                                        map[string]any
		Order                                              []string
		Paths                                              []string
		Target                                             string
		ProviderRoute                                      *ApplicationRoute
	}
	if len(req.Params) > MaxConfig {
		return nil, errors.New("request is too large")
	}
	if err := decode(req.Params, &q); err != nil {
		return nil, err
	}
	if req.Method == "preferences" {
		b, _ := json.Marshal(q.Preferences)
		if len(b) > 1<<20 {
			return nil, errors.New("preferences are too large")
		}
		old := a.Store.State.Preferences
		a.Store.State.Preferences = q.Preferences
		if err := a.Store.Save(); err != nil {
			a.Store.State.Preferences = old
			return nil, err
		}
		return true, nil
	}
	p, err := a.Store.Profile(q.ID)
	if err != nil {
		return nil, err
	}
	next := cloneProfile(*p)
	switch req.Method {
	case "batchApplicationRules":
		if len(q.Paths) == 0 || len(q.Paths) > 128 {
			return nil, errors.New("select between 1 and 128 applications")
		}
		var doc map[string]any
		if err = yaml.Unmarshal([]byte(next.Content), &doc); err != nil {
			return nil, err
		}
		rules, _ := doc["rules"].([]any)
		for _, path := range q.Paths {
			if path == "" || strings.ContainsAny(path, ",\r\n") {
				return nil, errors.New("invalid executable path")
			}
			prefix := "PROCESS-PATH," + path + ","
			rules = slices.DeleteFunc(rules, func(raw any) bool {
				rule, _ := raw.(string)
				if strings.HasPrefix(rule, prefix) {
					next.DesktopSuppressedRules = append(next.DesktopSuppressedRules, rule)
					return true
				}
				return false
			})
			next.DesktopRules = slices.DeleteFunc(next.DesktopRules, func(rule string) bool { return strings.HasPrefix(rule, prefix) })
			next.DisabledRules = slices.DeleteFunc(next.DisabledRules, func(rule string) bool { return strings.HasPrefix(rule, prefix) })
			target := q.Target
			if q.ProviderRoute != nil {
				route, _, routeErr := providerRoute(doc, ApplicationRoute{Kind: "PROCESS-PATH", Match: path, Provider: q.ProviderRoute.Provider, Node: q.ProviderRoute.Node})
				if routeErr != nil {
					return nil, routeErr
				}
				next.DesktopProviderRoutes = append(next.DesktopProviderRoutes, route)
				target = route.Group
			}
			if target == "" {
				return nil, errors.New("choose a route")
			}
			rule := prefix + target
			next.DesktopRules = append([]string{rule}, next.DesktopRules...)
			if len(next.RuleOrder) > 0 {
				next.RuleOrder = append([]string{rule}, next.RuleOrder...)
			}
		}
		doc["rules"] = rules
		b, _ := yaml.Marshal(doc)
		next.Content, err = mergeDesktopRules(string(b), next.DesktopRules)
		if err != nil {
			return nil, err
		}
		next.Content, err = mergeProviderRoutes(next.Content, next.DesktopProviderRoutes)
		if err != nil {
			return nil, err
		}
		next.Content, err = mergeWorkspace(next.Content, next)
	case "profileMetadata":
		if strings.TrimSpace(q.Name) == "" || len(q.Name) > 512 {
			return nil, errors.New("enter a configuration name")
		}
		if q.IntervalHours != nil && (*q.IntervalHours < 0 || *q.IntervalHours > 8760) {
			return nil, errors.New("invalid refresh interval")
		}
		next.Name = strings.TrimSpace(q.Name)
		if q.URL != "" {
			u, e := url.Parse(q.URL)
			if e != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
				return nil, errors.New("enter a valid HTTP/HTTPS subscription URL")
			}
			next.URL = q.URL
		}
		next.IntervalHours = q.IntervalHours
		old := *p
		*p = next
		if err = a.Store.Save(); err != nil {
			*p = old
		}
		return next, err
	case "duplicateProfile":
		next.ID = RandomID()
		next.Name = p.Name + " (copy)"
		next.URL = ""
		next.LastError = ""
		next.LastAttempt = time.Time{}
		a.Store.State.Profiles = append(a.Store.State.Profiles, next)
		if err = a.Store.Save(); err != nil {
			a.Store.State.Profiles = a.Store.State.Profiles[:len(a.Store.State.Profiles)-1]
		}
		return next, err
	case "previewRefresh":
		if p.URL == "" {
			return nil, errors.New("this configuration has no subscription URL")
		}
		content, usage, err := FetchSubscription(ctx, p.URL)
		if err != nil {
			p.LastError = err.Error()
			p.LastAttempt = time.Now().UTC()
			_ = a.Store.Save()
			return nil, err
		}
		imported, err := Import([]byte(content), "")
		if err != nil {
			return nil, err
		}
		content, err = mergeWorkspace(imported.Content, *p)
		if err != nil {
			return nil, err
		}
		content, err = suppressDesktopRules(content, p.DesktopSuppressedRules)
		if err != nil {
			return nil, err
		}
		content, err = mergeDesktopRules(content, p.DesktopRules)
		if err != nil {
			return nil, err
		}
		content, err = mergeProviderRoutes(content, p.DesktopProviderRoutes)
		if err != nil {
			return nil, err
		}
		content, err = mergeWorkspace(content, *p)
		if err != nil {
			return nil, err
		}
		if _, err = a.Core.Validate(ctx, content, a.Store.State.Settings, false); err != nil {
			return nil, err
		}
		v := SubscriptionPreview{ID: p.ID, Token: RandomID(), Added: []string{}, Removed: []string{}, Changed: []string{}, Warnings: imported.Warnings, content: content, usage: usage, before: profileStamp(*p), expires: time.Now().Add(10 * time.Minute)}
		before, after := objectInventory(p.Content), objectInventory(content)
		for name, value := range after {
			if old, ok := before[name]; !ok {
				v.Added = append(v.Added, name)
			} else if old != value {
				v.Changed = append(v.Changed, name)
			}
		}
		for name := range before {
			if _, ok := after[name]; !ok {
				v.Removed = append(v.Removed, name)
			}
		}
		slices.Sort(v.Added)
		slices.Sort(v.Removed)
		slices.Sort(v.Changed)
		if a.previews == nil {
			a.previews = map[string]SubscriptionPreview{}
		}
		for token, item := range a.previews {
			if item.ID == q.ID || time.Now().After(item.expires) {
				delete(a.previews, token)
			}
		}
		if len(a.previews) >= 32 {
			return nil, errors.New("too many pending previews")
		}
		a.previews[v.Token] = v
		return v, nil
	case "applyRefresh":
		v, ok := a.previews[q.Token]
		if !ok || v.ID != p.ID || time.Now().After(v.expires) || v.before != profileStamp(*p) {
			return nil, errors.New("preview expired or configuration changed; preview the update again")
		}
		next.Content = v.content
		next.Usage = v.usage
		next.Warnings = v.Warnings
		next.LastError = ""
		next.LastAttempt = time.Now().UTC()
		next.Updated = next.LastAttempt
		err = a.commitProfile(ctx, p, next)
		if err == nil {
			delete(a.previews, q.Token)
		}
		return next, err
	case "manageObject":
		if !slices.Contains([]string{"proxies", "proxy-groups", "proxy-providers", "rule-providers"}, q.Field) {
			return nil, errors.New("unsupported object type")
		}
		if q.OldName == "" || len(q.OldName) > 512 || stringsContainControl(q.OldName) || strings.HasPrefix(q.OldName, "Aster-App-") {
			return nil, errors.New("invalid or reserved name")
		}
		if q.Action == "create" {
			var doc map[string]any
			_ = yaml.Unmarshal([]byte(next.Content), &doc)
			for _, field := range []string{q.Field} {
				if objects, ok := doc[field].(map[string]any); ok {
					if _, ok = objects[q.OldName]; ok {
						return nil, errors.New("a name already exists; choose another name")
					}
				}
				if objects, ok := doc[field].([]any); ok {
					for _, raw := range objects {
						obj, _ := raw.(map[string]any)
						if obj["name"] == q.OldName {
							return nil, errors.New("a name already exists; choose another name")
						}
					}
				}
			}
		}
		if next.DesktopObjects == nil {
			next.DesktopObjects = map[string]map[string]map[string]any{}
		}
		if next.DesktopRemoved == nil {
			next.DesktopRemoved = map[string][]string{}
		}
		if next.DesktopObjects[q.Field] == nil {
			next.DesktopObjects[q.Field] = map[string]map[string]any{}
		}
		if q.Action == "delete" {
			delete(next.DesktopObjects[q.Field], q.OldName)
			next.DesktopRemoved[q.Field] = append(next.DesktopRemoved[q.Field], q.OldName)
		} else {
			if q.Object == nil {
				return nil, errors.New("object is required")
			}
			if strings.HasSuffix(q.Field, "providers") && q.Object["type"] == "file" {
				b, _ := yaml.Marshal(map[string]any{q.Field: map[string]any{q.OldName: q.Object}})
				content, err := InlineLocalProviders(string(b), filepath.Join(a.Store.Dir, "gui.yaml"))
				if err != nil {
					return nil, err
				}
				var doc map[string]any
				_ = yaml.Unmarshal([]byte(content), &doc)
				q.Object = doc[q.Field].(map[string]any)[q.OldName].(map[string]any)
			}
			if !strings.HasSuffix(q.Field, "providers") {
				if q.Object["name"] != q.OldName {
					return nil, errors.New("object name must match")
				}
			}
			next.DesktopObjects[q.Field][q.OldName] = q.Object
			next.DesktopRemoved[q.Field] = slices.DeleteFunc(next.DesktopRemoved[q.Field], func(name string) bool { return name == q.OldName })
		}
		next.Content, err = mergeWorkspace(next.Content, next)
	case "manageRules":
		var doc map[string]any
		if err = yaml.Unmarshal([]byte(next.Content), &doc); err != nil {
			return nil, err
		}
		rules, _ := doc["rules"].([]any)
		switch q.Action {
		case "disable":
			if !slices.Contains(rules, any(q.Rule)) {
				return nil, errors.New("rule no longer exists")
			}
			next.DisabledRules = append(next.DisabledRules, q.Rule)
			if len(next.RuleOrder) == 0 {
				for _, raw := range rules {
					if rule, ok := raw.(string); ok {
						next.RuleOrder = append(next.RuleOrder, rule)
					}
				}
			}
		case "enable":
			if !slices.Contains(next.DisabledRules, q.Rule) {
				return nil, errors.New("rule is not disabled")
			}
			next.DisabledRules = slices.DeleteFunc(next.DisabledRules, func(r string) bool { return r == q.Rule })
			rules = append([]any{q.Rule}, rules...)
			doc["rules"] = rules
		case "order":
			next.RuleOrder = q.Order
		default:
			return nil, errors.New("unsupported rule operation")
		}
		b, _ := yaml.Marshal(doc)
		next.Content, err = mergeWorkspace(string(b), next)
	default:
		return nil, errors.New("unsupported workspace operation")
	}
	if err != nil {
		return nil, err
	}
	next.Modified = time.Now().UTC()
	return next, a.commitProfile(ctx, p, next)
}
