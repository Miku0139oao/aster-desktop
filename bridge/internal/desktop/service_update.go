package desktop

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

func NewServiceCore(binary, dir string) *Core {
	core := NewCore(binary, dir)
	b, err := os.ReadFile(filepath.Join(filepath.Dir(dir), "cores", "selection.json"))
	if err == nil {
		var selection map[string]string
		if json.Unmarshal(b, &selection) == nil {
			path := selection["active"]
			if filepath.Dir(path) == filepath.Join(filepath.Dir(dir), "cores") {
				if _, err = os.Stat(path); err == nil {
					core.Binary = path
				}
			}
		}
	}
	return core
}
func UpdateServiceCore(ctx context.Context, core *Core) (any, error) {
	if core.Status().Running {
		return nil, errors.New("disconnect before updating the background core")
	}
	app, err := NewApp(filepath.Dir(core.Dir), core.Binary, "")
	if err != nil {
		return nil, err
	}
	app.Core = core
	app.Privileged = true
	defer app.Close()
	if content, err := os.ReadFile(filepath.Join(core.Dir, "runtime.yaml")); err == nil {
		app.Store.State.Profiles = []Profile{{ID: "last-runtime", Content: string(content)}}
		app.Store.State.ActiveID = "last-runtime"
	}
	return app.UpdateCore(ctx)
}
