//go:build ios

package main

import "errors"

func installPlatform(string) error {
	return errors.New("iOS uses the NetworkExtension provider")
}

func removePlatform() error {
	return errors.New("iOS uses the NetworkExtension provider")
}

func runPrivilegedStdio(string, string) error {
	return errors.New("privileged stdio is not used on iOS")
}
