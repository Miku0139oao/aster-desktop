//go:build android

package main

import "errors"

func installPlatform(string) error {
	return errors.New("Android uses the in-process VPN service")
}

func removePlatform() error {
	return errors.New("Android uses the in-process VPN service")
}

func runPrivilegedStdio(string, string) error {
	return errors.New("privileged stdio is not used on Android")
}
