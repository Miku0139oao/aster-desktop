//go:build !android

package mobileapi

// iOS and desktop-hosted tests have no Android-only resolver override; the
// addresses are applied through the core's runtime configuration instead.
func updatePlatformDNS([]string) error { return nil }
