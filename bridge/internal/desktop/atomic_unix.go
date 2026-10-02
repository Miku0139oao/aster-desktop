//go:build !windows

package desktop

import "os"

func replaceFile(from, to string) error { return os.Rename(from, to) }
