package desktop

import (
	"context"
	"encoding/json"
	"os/exec"
	"strings"
	"time"
)

type ProxyTarget struct {
	Name      string            `json:"name"`
	Before    map[string]string `json:"before"`
	Installed map[string]string `json:"installed"`
}
type ProxySnapshot struct {
	Backend string        `json:"backend"`
	Targets []ProxyTarget `json:"targets"`
}

func command(name string, args ...string) (string, error) {
	timeout := 15 * time.Second
	if name == "pkexec" {
		timeout = 2 * time.Minute
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	c := exec.CommandContext(ctx, name, args...)
	hideCommand(c)
	b, err := c.CombinedOutput()
	return strings.TrimSpace(string(b)), err
}
func encodeSnapshot(p ProxySnapshot) []byte { b, _ := json.Marshal(p); return b }

// A setting is restored only if its currently installed value is still ours.
// Linked enable/mode flags are guarded by the endpoint values they control.
func ownedProxyValues(t ProxyTarget, current map[string]string, flag string, endpoints []string, groups ...[]string) map[string]string {
	next := map[string]string{}
	for k, v := range current {
		next[k] = v
	}
	endpointsOwned := true
	blocked := map[string]bool{}
	for _, group := range groups {
		owned := true
		for _, key := range group {
			if current[key] != t.Installed[key] {
				owned = false
			}
		}
		if !owned {
			for _, key := range group {
				blocked[key] = true
			}
		}
	}
	for _, key := range endpoints {
		if current[key] != t.Installed[key] {
			endpointsOwned = false
		}
	}
	for key, installed := range t.Installed {
		if current[key] == installed && !blocked[key] && (key != flag || endpointsOwned) {
			next[key] = t.Before[key]
		}
	}
	return next
}
