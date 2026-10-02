package desktop

import (
	"fmt"
)

func PrepareDownloadedCore(path string) error {
	out, err := command("/usr/bin/codesign", "--force", "--sign", "-", path)
	if err != nil {
		return fmt.Errorf("cannot sign downloaded core: %s", out)
	}
	return nil
}
