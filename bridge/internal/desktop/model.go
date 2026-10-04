package desktop

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const CoreCommit = "a9a33503b39a03681bc52d9758907316a22df199"
const Version = "0.1.4"
const MaxConfig = 16 << 20

type Settings struct {
	Language          string `json:"language"`
	Theme             string `json:"theme"`
	SystemProxy       bool   `json:"systemProxy"`
	Tun               bool   `json:"tun"`
	AllowLAN          bool   `json:"allowLan"`
	MixedPort         int    `json:"mixedPort"`
	Mode              string `json:"mode"`
	AutoStart         bool   `json:"autoStart"`
	SubscriptionHours int    `json:"subscriptionHours"`
}

func DefaultSettings() Settings {
	return Settings{Language: "zh_TW", Theme: "system", SystemProxy: true, MixedPort: 7890, Mode: "rule", SubscriptionHours: 24}
}
func (s Settings) Validate() error {
	if s.MixedPort < 1024 || s.MixedPort > 65535 {
		return errors.New("proxy port must be between 1024 and 65535")
	}
	if s.Mode != "rule" && s.Mode != "global" && s.Mode != "direct" {
		return errors.New("invalid proxy mode")
	}
	if s.Language != "zh_TW" && s.Language != "en" {
		return errors.New("invalid language")
	}
	if s.Theme != "system" && s.Theme != "light" && s.Theme != "dark" {
		return errors.New("invalid theme")
	}
	if s.SubscriptionHours < 0 || s.SubscriptionHours > 8760 {
		return errors.New("invalid subscription interval")
	}
	return nil
}

type Profile struct {
	ID                     string          `json:"id"`
	Name                   string          `json:"name"`
	URL                    string          `json:"url,omitempty"`
	Content                string          `json:"content"`
	Updated                time.Time       `json:"updated"`
	Warnings               []string        `json:"warnings,omitempty"`
	Usage                  string          `json:"usage,omitempty"`
	LastError              string          `json:"lastError,omitempty"`
	DesktopRules           []string        `json:"desktopRules,omitempty"`
	DesktopSuppressedRules []string        `json:"desktopSuppressedRules,omitempty"`
	DesktopProviderRoutes  []ProviderRoute `json:"desktopProviderRoutes,omitempty"`
}
type State struct {
	Settings   Settings          `json:"settings"`
	Profiles   []Profile         `json:"profiles"`
	ActiveID   string            `json:"activeId"`
	Selections map[string]string `json:"selections"`
}
type Store struct {
	mu    sync.Mutex
	Dir   string
	State State
}

func OpenStore(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	s := &Store{Dir: dir, State: State{Settings: DefaultSettings(), Profiles: []Profile{}, Selections: map[string]string{}}}
	b, err := os.ReadFile(filepath.Join(dir, "state.json"))
	if err == nil {
		if err = json.Unmarshal(b, &s.State); err != nil {
			return nil, fmt.Errorf("saved settings are damaged: %w", err)
		}
	} else if !os.IsNotExist(err) {
		return nil, err
	}
	if s.State.Selections == nil {
		s.State.Selections = map[string]string{}
	}
	return s, nil
}
func (s *Store) Save() error {
	b, err := json.MarshalIndent(s.State, "", "  ")
	if err != nil {
		return err
	}
	return AtomicWrite(filepath.Join(s.Dir, "state.json"), b, 0600)
}
func (s *Store) Profile(id string) (*Profile, error) {
	for i := range s.State.Profiles {
		if s.State.Profiles[i].ID == id {
			return &s.State.Profiles[i], nil
		}
	}
	return nil, errors.New("configuration not found")
}
func RandomID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}
func AtomicWrite(path string, b []byte, perm os.FileMode) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".aster-*")
	if err != nil {
		return err
	}
	name := f.Name()
	defer os.Remove(name)
	if err = f.Chmod(perm); err == nil {
		_, err = f.Write(b)
	}
	if err == nil {
		err = f.Sync()
	}
	ce := f.Close()
	if err == nil {
		err = ce
	}
	if err != nil {
		return err
	}
	return replaceFile(name, path)
}
