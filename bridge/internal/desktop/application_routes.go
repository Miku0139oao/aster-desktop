package desktop

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"reflect"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"
)

// Provider proxies are not global rule targets. A private, exact-filtered group
// gives each application's choice an independent target using existing core APIs.
type ProviderRoute struct {
	Group    string `json:"group"`
	Provider string `json:"provider"`
	Node     string `json:"node"`
}

type ApplicationRoute struct {
	Kind     string
	Match    string
	Provider string
	Node     string
}

func providerRoute(doc map[string]any, route ApplicationRoute) (ProviderRoute, string, error) {
	if route.Kind != "PROCESS-PATH" && route.Kind != "PROCESS-NAME" && route.Kind != "DOMAIN" && route.Kind != "DOMAIN-SUFFIX" && route.Kind != "IP-CIDR" && route.Kind != "IP-CIDR6" {
		return ProviderRoute{}, "", errors.New("unsupported application rule kind")
	}
	if route.Match == "" || route.Provider == "" || route.Node == "" || strings.ContainsAny(route.Match, ",\r\n") || strings.ContainsAny(route.Node, "\r\n") {
		return ProviderRoute{}, "", errors.New("invalid application or provider node")
	}
	providers, _ := doc["proxy-providers"].(map[string]any)
	if _, ok := providers[route.Provider]; !ok {
		return ProviderRoute{}, "", errors.New("this provider is no longer in the configuration")
	}
	hash := sha256.Sum256([]byte(route.Kind + "\x00" + route.Match + "\x00" + route.Provider + "\x00" + route.Node))
	r := ProviderRoute{Group: fmt.Sprintf("Aster-App-%x", hash[:12]), Provider: route.Provider, Node: route.Node}
	return r, route.Kind + "," + route.Match + "," + r.Group, nil
}

func (r ProviderRoute) config() map[string]any {
	// Backticks separate multiple core filters; escape as regex codepoint instead.
	filter := strings.ReplaceAll(regexp.QuoteMeta(r.Node), "`", `\x60`)
	return map[string]any{"name": r.Group, "type": "select", "use": []any{r.Provider}, "filter": "^" + filter + "$", "empty-fallback": "REJECT", "hidden": true}
}

func mergeProviderRoutes(content string, routes []ProviderRoute) (string, error) {
	if len(routes) == 0 {
		return content, nil
	}
	var doc map[string]any
	if err := yaml.Unmarshal([]byte(content), &doc); err != nil {
		return "", err
	}
	if doc == nil {
		return "", errors.New("configuration must be a YAML mapping")
	}
	groups, _ := doc["proxy-groups"].([]any)
	providers, _ := doc["proxy-providers"].(map[string]any)
	for _, route := range routes {
		if _, exists := providers[route.Provider]; !exists {
			return "", errors.New("an application route's provider was removed; choose another route before updating")
		}
		found := false
		for _, val := range groups {
			group, _ := val.(map[string]any)
			if group["name"] == route.Group {
				if !reflect.DeepEqual(group, route.config()) {
					return "", errors.New("an application route group conflicts with the configuration")
				}
				found = true
			}
		}
		if !found {
			groups = append(groups, route.config())
		}
	}
	doc["proxy-groups"] = groups
	b, err := yaml.Marshal(doc)
	return string(b), err
}

func retainedProviderRoutes(content string, routes []ProviderRoute) []ProviderRoute {
	var doc map[string]any
	if yaml.Unmarshal([]byte(content), &doc) != nil {
		return nil
	}
	groups, _ := doc["proxy-groups"].([]any)
	rules, _ := doc["rules"].([]any)
	result := []ProviderRoute{}
	seen := map[string]bool{}
	for _, route := range routes {
		if seen[route.Group] {
			continue
		}
		used := false
		for _, val := range rules {
			rule, _ := val.(string)
			parts := strings.Split(rule, ",")
			if len(parts) >= 2 && (parts[len(parts)-1] == route.Group || (parts[len(parts)-1] == "no-resolve" && parts[len(parts)-2] == route.Group)) {
				used = true
			}
		}
		for _, val := range groups {
			group, _ := val.(map[string]any)
			if used && reflect.DeepEqual(group, route.config()) {
				result = append(result, route)
				seen[route.Group] = true
				break
			}
		}
	}
	return result
}
