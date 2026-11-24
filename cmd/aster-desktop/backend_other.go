//go:build !darwin

package main

import "github.com/Miku0139oao/aster-desktop/internal/backend"

func withPlatformBackend(client backend.Client, _ string) backend.Client { return client }
