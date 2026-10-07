package desktop

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"time"
)

type TrafficDay struct {
	Date         string                   `json:"date"`
	Upload       uint64                   `json:"upload"`
	Download     uint64                   `json:"download"`
	Applications map[string]TrafficTotals `json:"applications,omitempty"`
	Routes       map[string]TrafficTotals `json:"routes,omitempty"`
}
type TrafficTotals struct {
	Upload   uint64 `json:"upload"`
	Download uint64 `json:"download"`
}
type TrafficConnection struct {
	ID       string   `json:"id"`
	Upload   uint64   `json:"upload"`
	Download uint64   `json:"download"`
	Chains   []string `json:"chains"`
	Metadata struct {
		Process string `json:"process"`
		Path    string `json:"processPath"`
	} `json:"metadata"`
}
type TrafficHistory struct {
	mu          sync.Mutex
	path        string
	days        []TrafficDay
	session     string
	up, down    uint64
	dirty       bool
	lastSave    time.Time
	lastError   string
	connections map[string]TrafficTotals
}

func NewTrafficHistory(dir string) *TrafficHistory {
	h := &TrafficHistory{path: filepath.Join(dir, "traffic-history.json"), days: []TrafficDay{}}
	b, err := os.ReadFile(h.path)
	if err == nil {
		if err = json.Unmarshal(b, &h.days); err != nil {
			h.days = []TrafficDay{}
			h.lastError = "saved traffic history could not be read"
		}
	}
	if err != nil && !os.IsNotExist(err) {
		h.lastError = err.Error()
	}
	return h
}
func (h *TrafficHistory) record(session string, up, down uint64, now time.Time) {
	h.mu.Lock()
	defer h.mu.Unlock()
	// New core sessions and counter resets start at zero; repeated snapshots
	// contribute only the delta. Clearing history keeps this baseline intact.
	du, dd := up, down
	if session != h.session {
		h.connections = nil
	}
	if session == h.session {
		if up >= h.up {
			du = up - h.up
		}
		if down >= h.down {
			dd = down - h.down
		}
	}
	h.session = session
	h.up = up
	h.down = down
	if du == 0 && dd == 0 {
		return
	}
	date := now.Format("2006-01-02")
	i := slices.IndexFunc(h.days, func(d TrafficDay) bool { return d.Date == date })
	if i < 0 {
		h.days = append(h.days, TrafficDay{Date: date})
		i = len(h.days) - 1
	}
	h.days[i].Upload += du
	h.days[i].Download += dd
	cutoff := now.AddDate(0, 0, -364).Format("2006-01-02")
	h.days = slices.DeleteFunc(h.days, func(d TrafficDay) bool { return d.Date < cutoff })
	slices.SortFunc(h.days, func(a, b TrafficDay) int {
		if a.Date < b.Date {
			return -1
		}
		if a.Date > b.Date {
			return 1
		}
		return 0
	})
	h.dirty = true
	if now.Sub(h.lastSave) >= 15*time.Second {
		_ = h.saveLocked(now)
	}
}

func (h *TrafficHistory) recordConnections(connections []TrafficConnection, now time.Time) {
	h.mu.Lock()
	defer h.mu.Unlock()
	date := now.Format("2006-01-02")
	i := slices.IndexFunc(h.days, func(d TrafficDay) bool { return d.Date == date })
	if i < 0 {
		return
	}
	day := &h.days[i]
	if day.Applications == nil {
		day.Applications = map[string]TrafficTotals{}
	}
	if day.Routes == nil {
		day.Routes = map[string]TrafficTotals{}
	}
	next := map[string]TrafficTotals{}
	for _, c := range connections {
		previous := h.connections[c.ID]
		up, down := c.Upload, c.Download
		if c.Upload >= previous.Upload {
			up -= previous.Upload
		}
		if c.Download >= previous.Download {
			down -= previous.Download
		}
		next[c.ID] = TrafficTotals{c.Upload, c.Download}
		if up == 0 && down == 0 {
			continue
		}
		app := c.Metadata.Process
		if app == "" {
			app = filepath.Base(c.Metadata.Path)
		}
		if app == "" || app == "." {
			app = "Unknown"
		}
		route := "DIRECT"
		if len(c.Chains) > 0 {
			route = c.Chains[0]
		}
		for _, entry := range []struct {
			table map[string]TrafficTotals
			key   string
		}{{day.Applications, app}, {day.Routes, route}} {
			key := entry.key
			if _, ok := entry.table[key]; !ok && len(entry.table) >= 256 {
				key = "Other"
			}
			value := entry.table[key]
			value.Upload += up
			value.Download += down
			entry.table[key] = value
		}
		h.dirty = true
	}
	h.connections = next
}
func (h *TrafficHistory) saveLocked(now time.Time) error {
	if !h.dirty {
		return nil
	}
	b, err := json.Marshal(h.days)
	if err == nil {
		err = AtomicWrite(h.path, b, 0600)
	}
	if err != nil {
		h.lastError = err.Error()
		return err
	}
	h.dirty = false
	h.lastSave = now
	h.lastError = ""
	return nil
}
func (h *TrafficHistory) Flush() error {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.saveLocked(time.Now())
}
func (h *TrafficHistory) Snapshot(window ...int) map[string]any {
	h.mu.Lock()
	defer h.mu.Unlock()
	count := 365
	if len(window) > 0 {
		count = window[0]
	}
	if count < 1 || count > 365 {
		count = 365
	}
	cutoff := time.Now().AddDate(0, 0, 1-count).Format("2006-01-02")
	filtered := []TrafficDay{}
	for _, day := range h.days {
		if day.Date >= cutoff {
			filtered = append(filtered, day)
		}
	}
	b, _ := json.Marshal(filtered)
	var days []TrafficDay
	_ = json.Unmarshal(b, &days)
	return map[string]any{"days": days, "error": h.lastError, "retentionDays": 365, "windowDays": count}
}
func (h *TrafficHistory) Clear() error {
	h.mu.Lock()
	defer h.mu.Unlock()
	old := h.days
	h.days = []TrafficDay{}
	h.dirty = true
	if err := h.saveLocked(time.Now()); err != nil {
		h.days = old
		h.dirty = true
		return err
	}
	return nil
}
func (a *App) collectTraffic(ctx context.Context) {
	a.mu.Lock()
	defer a.mu.Unlock()
	status := a.status()
	if !status.Running || a.metrics == nil {
		return
	}
	result, err := a.dispatchCore(ctx, "GET", "/connections", nil)
	if err != nil {
		return
	}
	var counters struct {
		Upload      uint64              `json:"uploadTotal"`
		Download    uint64              `json:"downloadTotal"`
		Connections []TrafficConnection `json:"connections"`
	}
	if json.Unmarshal(result, &counters) == nil {
		a.metrics.record(trafficSession(status), counters.Upload, counters.Download, time.Now())
		a.metrics.recordConnections(counters.Connections, time.Now())
	}
}
func trafficSession(s CoreStatus) string {
	b, _ := json.Marshal([]any{s.PID, s.Version})
	return string(b)
}
func (a *App) trafficLoop(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			if a.metrics != nil {
				_ = a.metrics.Flush()
			}
			return
		case <-ticker.C:
			sample, cancel := context.WithTimeout(ctx, 3*time.Second)
			a.collectTraffic(sample)
			cancel()
		}
	}
}
