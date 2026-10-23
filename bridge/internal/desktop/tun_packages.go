package desktop

import (
	"regexp"
	"strings"
)

// Android package names are Java identifiers separated by dots. The core also
// receives them, so reject anything that could not be produced by
// PackageManager before it reaches the configuration.
var androidPackagePattern = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*$`)

const maxTunPackages = 512

// NormalizeTunPackages keeps valid, unique package names in their original
// order and drops packages that are also excluded.
func NormalizeTunPackages(include, exclude []string) ([]string, []string) {
	excluded := normalizePackageList(exclude)
	excludedSet := make(map[string]bool, len(excluded))
	for _, name := range excluded {
		excludedSet[name] = true
	}
	normalized := make([]string, 0, len(include))
	for _, name := range normalizePackageList(include) {
		if !excludedSet[name] {
			normalized = append(normalized, name)
		}
	}
	return normalized, excluded
}

func normalizePackageList(values []string) []string {
	result := make([]string, 0, len(values))
	seen := make(map[string]bool, len(values))
	for _, value := range values {
		name := strings.TrimSpace(value)
		if name == "" || len(name) > 255 || !androidPackagePattern.MatchString(name) || seen[name] {
			continue
		}
		seen[name] = true
		result = append(result, name)
		if len(result) == maxTunPackages {
			break
		}
	}
	return result
}

// SetTunPackages updates the per-application rules used the next time the
// in-process core starts or applies a configuration.
func (c *Core) SetTunPackages(include, exclude []string) {
	include, exclude = NormalizeTunPackages(include, exclude)
	c.mu.Lock()
	c.includePackages = include
	c.excludePackages = exclude
	c.mu.Unlock()
}

func (c *Core) tunPackages() ([]string, []string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]string{}, c.includePackages...), append([]string{}, c.excludePackages...)
}

// applyMobileTunOptions owns the fields that differ when Android supplies the
// TUN descriptor. auto-route must stay off because VpnService owns routing, and
// auto-detect-interface must stay off because its netlink-based monitor is
// banned for Android 14+ apps. The core's sockets are protected through
// VpnService.protect(), which makes interface binding unnecessary.
func applyMobileTunOptions(tun map[string]any, fd int, include, exclude []string) {
	tun["auto-route"] = false
	tun["auto-detect-interface"] = false
	delete(tun, "file-descriptor")
	delete(tun, "include-package")
	delete(tun, "exclude-package")
	if fd > 0 {
		tun["file-descriptor"] = fd
	}
	if len(include) > 0 {
		tun["include-package"] = packageValues(include)
	}
	if len(exclude) > 0 {
		tun["exclude-package"] = packageValues(exclude)
	}
}

func packageValues(values []string) []any {
	result := make([]any, len(values))
	for index, value := range values {
		result[index] = value
	}
	return result
}
