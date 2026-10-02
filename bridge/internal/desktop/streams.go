package desktop

import (
	"context"
	"encoding/json"
	"github.com/coder/websocket"
	"net/http"
	"time"
)

func (a *App) beginStreams() {
	if a.remote != nil {
		return
	}
	a.Core.mu.Lock()
	done := a.Core.done
	address := a.Core.Address
	secret := a.Core.Secret
	a.Core.mu.Unlock()
	for _, path := range []string{"/traffic", "/connections"} {
		go func(path string) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			go func() { <-done; cancel() }()
			for ctx.Err() == nil {
				conn, _, err := websocket.Dial(ctx, "ws://"+address+path, &websocket.DialOptions{HTTPHeader: http.Header{"Authorization": []string{"Bearer " + secret}}, HTTPClient: a.Core.client})
				if err == nil {
					conn.SetReadLimit(MaxConfig)
					for {
						_, data, err := conn.Read(ctx)
						if err != nil {
							break
						}
						var value any
						if json.Unmarshal(data, &value) == nil {
							a.Emit(path[1:], value)
						}
					}
					_ = conn.Close(websocket.StatusNormalClosure, "")
				}
				select {
				case <-ctx.Done():
					return
				case <-time.After(time.Second):
				}
			}
		}(path)
	}
}
func (a *App) Schedule(ctx context.Context) {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			a.mu.Lock()
			hours := a.Store.State.Settings.SubscriptionHours
			ids := []string{}
			if hours > 0 {
				for _, p := range a.Store.State.Profiles {
					if p.URL != "" && time.Since(p.Updated) >= time.Duration(hours)*time.Hour {
						ids = append(ids, p.ID)
					}
				}
			}
			a.mu.Unlock()
			for _, id := range ids {
				b, _ := json.Marshal(map[string]string{"id": id})
				_, err := a.Dispatch(ctx, Request{Method: "refresh", Params: b})
				if err != nil {
					a.Emit("subscriptionError", map[string]string{"id": id, "message": err.Error()})
				} else {
					a.Emit("profilesChanged", nil)
				}
			}
		}
	}
}
