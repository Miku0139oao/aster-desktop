package main

import (
	"path/filepath"

	"github.com/Miku0139oao/aster-desktop/internal/backend"
)

func withPlatformBackend(client backend.Client, executable string) backend.Client {
	library := filepath.Join(filepath.Dir(executable), "..", "Frameworks", "libAsterPrivilege.dylib")
	return backend.WithMacService(client, library)
}
