package desktop

import (
	"context"
	"encoding/json"
	"os"
	"testing"
)

func TestForgetSelectionPersistsOnlyRequestedGroup(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	app, err := NewApp(t.TempDir(), executable, "")
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	app.Store.State.Selections["Auto"] = "Tokyo"
	app.Store.State.Selections["Manual"] = "Singapore"
	params, _ := json.Marshal(map[string]string{"group": "Auto"})
	if _, err = app.Dispatch(context.Background(), Request{Method: "forgetSelection", Params: params}); err != nil {
		t.Fatal(err)
	}
	reloaded, err := OpenStore(app.Store.Dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, exists := reloaded.State.Selections["Auto"]; exists {
		t.Fatal("manual override persisted")
	}
	if reloaded.State.Selections["Manual"] != "Singapore" {
		t.Fatal("unrelated group selection lost")
	}
	if _, err = app.Dispatch(context.Background(), Request{Method: "forgetSelection", Params: json.RawMessage(`{"group":""}`)}); err == nil {
		t.Fatal("empty group accepted")
	}
}
