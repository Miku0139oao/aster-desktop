package desktop

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	C "github.com/Miku0139oao/aster-core/constant"
	"github.com/Miku0139oao/aster-core/dns"
	"github.com/Miku0139oao/aster-core/hub"
	"github.com/Miku0139oao/aster-core/hub/executor"
	"github.com/Miku0139oao/aster-core/listener"
	"github.com/sirupsen/logrus"

	"gopkg.in/yaml.v3"
)

type Core struct {
	InProcess                    bool
	mu                           sync.Mutex
	Binary, Dir, Address, Secret string
	BundledBinary                string
	running                      bool
	fd                           int
	includePackages              []string
	excludePackages              []string
	cmd                          *exec.Cmd
	done                         chan struct{}
	runCancel                    context.CancelFunc
	lastError                    string
	stopping                     bool
	coreVersion                  string
	activeContent                string
	activeSettings               Settings
	logMu                        sync.Mutex
	logs                         []string
	proxy                        *ProxySnapshot
	proxyMu                      sync.Mutex
	client                       *http.Client
}
type CoreStatus struct {
	Running bool   `json:"running"`
	Error   string `json:"error,omitempty"`
	Version string `json:"version"`
	PID     int    `json:"pid,omitempty"`
}

func NewCore(binary, dir string) *Core {
	return &Core{Binary: binary, BundledBinary: binary, Dir: dir, Secret: RandomID() + RandomID(), client: &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{Proxy: nil}}, logs: []string{}}
}
func (c *Core) Status() CoreStatus {
	c.mu.Lock()
	defer c.mu.Unlock()
	s := CoreStatus{Error: c.lastError, Version: c.coreVersion}
	if c.cmd != nil {
		s.Running = true
		s.PID = c.cmd.Process.Pid
	}
	if c.InProcess {
		s.Running = c.running
		s.PID = os.Getpid()
	}
	return s
}
func (c *Core) appendLog(line string) {
	c.logMu.Lock()
	defer c.logMu.Unlock()
	c.logs = append(c.logs, line)
	if len(c.logs) > 2000 {
		c.logs = append([]string(nil), c.logs[len(c.logs)-1500:]...)
	}
}
func (c *Core) Logs() []string {
	c.logMu.Lock()
	defer c.logMu.Unlock()
	return append([]string{}, c.logs...)
}
func (c *Core) Validate(ctx context.Context, content string, s Settings, privileged bool) ([]byte, error) {
	if c.InProcess {
		if err := os.MkdirAll(c.Dir, 0700); err != nil {
			return nil, err
		}
		// The core otherwise looks for geodata under $HOME/.config/mihomo,
		// which is not writable (or even present) for an Android app.
		C.SetHomeDir(c.Dir)
		b, err := Runtime(content, s, c.Address, c.Secret, c.Dir, privileged)
		if err != nil {
			return nil, err
		}
		if _, err = executor.ParseWithBytes(b); err != nil {
			return nil, fmt.Errorf("configuration validation failed: %w", err)
		}
		return b, nil
	}
	if _, err := os.Stat(c.Binary); err != nil {
		return nil, errors.New("bundled core is missing; reinstall Aster Desktop")
	}
	if err := os.MkdirAll(c.Dir, 0700); err != nil {
		return nil, err
	}
	b, err := Runtime(content, s, "127.0.0.1:0", c.Secret, c.Dir, privileged)
	if err != nil {
		return nil, err
	}
	f, err := os.CreateTemp(c.Dir, "validate-*.yaml")
	if err != nil {
		return nil, err
	}
	name := f.Name()
	defer os.Remove(name)
	_ = f.Chmod(0600)
	if _, err = f.Write(b); err != nil {
		f.Close()
		return nil, err
	}
	f.Close()
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, c.Binary, "-d", c.Dir, "-f", name, "-t")
	hideCommand(cmd)
	if output, err := cmd.CombinedOutput(); err != nil {
		return nil, fmt.Errorf("configuration validation failed: %w\n%s", err, bounded(string(output), 3000))
	}
	return b, nil
}
func (c *Core) recordError(err error) {
	c.mu.Lock()
	c.lastError = err.Error()
	c.mu.Unlock()
	c.appendLog("Desktop: " + err.Error())
}

func (c *Core) Start(ctx context.Context, content string, s Settings, privileged bool) (result error) {
	if c.Status().Running {
		return errors.New("core is already running")
	}
	defer func() {
		if result != nil {
			c.recordError(result)
		}
	}()
	err := c.start(ctx, content, s, privileged)
	if err == nil || c.Binary == c.BundledBinary || ctx.Err() != nil {
		return err
	}
	selectionPath := filepath.Join(filepath.Dir(c.Dir), "cores", "selection.json")
	b, readErr := os.ReadFile(selectionPath)
	if readErr != nil {
		return err
	}
	var selection map[string]string
	if json.Unmarshal(b, &selection) != nil || selection["active"] != c.Binary {
		return err
	}
	previous := selection["previous"]
	if previous == "" || (previous != c.BundledBinary && filepath.Dir(previous) != filepath.Dir(selectionPath)) {
		return err
	}
	failed := c.Binary
	_ = c.Stop()
	c.Binary = previous
	if restoreErr := c.start(ctx, content, s, privileged); restoreErr != nil {
		c.Binary = failed
		return fmt.Errorf("new core failed (%v); the previous core could not start: %w", err, restoreErr)
	}
	selection["active"] = previous
	selection["previous"] = c.BundledBinary
	selection["failed"] = failed
	b, _ = json.Marshal(selection)
	writeErr := AtomicWrite(selectionPath, b, 0600)
	c.mu.Lock()
	c.lastError = "new core failed; previous version restored"
	if writeErr != nil {
		c.lastError += "; selection could not be saved"
	}
	c.mu.Unlock()
	c.appendLog("Core rollback: " + err.Error())
	return nil
}
func (c *Core) start(ctx context.Context, content string, s Settings, privileged bool) error {
	if c.Status().Running {
		return errors.New("core is already running")
	}
	if c.InProcess {
		return c.startInProcess(ctx, content, s)
	}
	if _, err := c.Validate(ctx, content, s, privileged); err != nil {
		return err
	}
	if s.Tun && s.TunInterface != "" {
		if err := validateTunInterface(s.TunInterface); err != nil {
			return err
		}
		c.appendLog("Desktop: TUN outbound interface: " + s.TunInterface)
	}
	bind := "127.0.0.1"
	if s.AllowLAN {
		bind = ""
	}
	listener, err := net.Listen("tcp", net.JoinHostPort(bind, fmt.Sprint(s.MixedPort)))
	if err != nil {
		return fmt.Errorf("proxy port %d is in use; stop the other proxy or choose another port in Advanced settings", s.MixedPort)
	}
	packet, err := net.ListenPacket("udp", net.JoinHostPort(bind, fmt.Sprint(s.MixedPort)))
	if err != nil {
		_ = listener.Close()
		return fmt.Errorf("proxy UDP port %d is unavailable; stop the other proxy or choose another port in Advanced settings", s.MixedPort)
	}
	l, err := net.Listen("tcp", "127.0.0.1:0")
	_ = listener.Close()
	_ = packet.Close()
	if err != nil {
		return err
	}
	address := l.Addr().String()
	l.Close()
	b, err := Runtime(content, s, address, c.Secret, c.Dir, privileged)
	if err != nil {
		return err
	}
	path := filepath.Join(c.Dir, "runtime.yaml")
	if err = AtomicWrite(path, b, 0600); err != nil {
		return err
	}
	cmd := exec.Command(c.Binary, "-d", c.Dir, "-f", path)
	if err = prepareCore(cmd); err != nil {
		return err
	}
	r, w := io.Pipe()
	cmd.Stdout = w
	cmd.Stderr = w
	if err = cmd.Start(); err != nil {
		r.Close()
		w.Close()
		return err
	}
	if err = containCore(cmd); err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		r.Close()
		w.Close()
		return err
	}
	c.mu.Lock()
	c.cmd = cmd
	c.done = make(chan struct{})
	c.Address = address
	c.lastError = ""
	c.stopping = false
	done := c.done
	c.mu.Unlock()
	logDone := make(chan struct{})
	go func() {
		defer close(logDone)
		scanner := bufio.NewScanner(r)
		scanner.Buffer(make([]byte, 4096), 64<<10)
		for scanner.Scan() {
			c.appendLog(scanner.Text())
		}
		r.Close()
	}()
	go func() {
		err := cmd.Wait()
		w.Close()
		<-logDone
		releaseCore(cmd)
		// Finish restoring this generation's proxy before allowing another start.
		_ = c.restoreProxy()
		c.mu.Lock()
		if c.cmd == cmd {
			c.cmd = nil
			if !c.stopping {
				c.lastError = "core stopped unexpectedly; reconnect to try again"
				if err != nil {
					c.lastError += ": " + err.Error()
				}
				c.lastError += "\n" + bounded(strings.Join(c.Logs(), "\n"), 3000)
			}
		}
		close(done)
		c.mu.Unlock()
	}()
	// The core starts its controller after loading proxy and rule providers.
	// Each HTTP provider phase may take 20 seconds with a cold cache. Do not
	// kill an already-created TUN while those two phases are still running.
	startupLimit := startupTimeout(b)
	startupCtx, cancelStartup := context.WithTimeout(ctx, startupLimit)
	defer cancelStartup()
	deadline := time.NewTimer(startupLimit)
	defer deadline.Stop()
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	stage := "controller"
	for {
		select {
		case <-ctx.Done():
			_ = c.Stop()
			return ctx.Err()
		case <-done:
			return fmt.Errorf("core did not start: %s", c.Status().Error)
		case <-deadline.C:
			_ = c.Stop()
			if stage == "tun" {
				return fmt.Errorf("TUN adapter did not become ready; check the background service and conflicting VPN software\n%s", bounded(strings.Join(c.Logs(), "\n"), 3000))
			}
			return fmt.Errorf("core startup timed out while waiting for %s; remote providers may be unavailable\n%s", stage, bounded(strings.Join(c.Logs(), "\n"), 3000))
		case <-ticker.C:
			probeCtx, cancelProbe := context.WithTimeout(startupCtx, time.Second)
			body, err := c.Request(probeCtx, "GET", "/version", nil)
			cancelProbe()
			if err == nil {
				var version struct {
					Version string `json:"version"`
				}
				if json.Unmarshal(body, &version) != nil || version.Version == "" {
					continue
				}
				// Controller readiness precedes binding the proxy listeners.
				stage = "proxy listener"
				listener, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", s.MixedPort), 250*time.Millisecond)
				if err != nil {
					continue
				}
				_ = listener.Close()
				if s.Tun {
					// The HTTP controller and proxy listeners can start even when
					// the OS rejects creating TUN. Report connected only after the
					// core reports the successfully applied TUN listener config.
					stage = "tun"
					probeCtx, cancelProbe := context.WithTimeout(startupCtx, time.Second)
					config, err := c.Request(probeCtx, "GET", "/configs", nil)
					cancelProbe()
					var active struct {
						Tun struct {
							Enable bool `json:"enable"`
						} `json:"tun"`
					}
					if err != nil || json.Unmarshal(config, &active) != nil || !active.Tun.Enable {
						continue
					}
				}
				c.mu.Lock()
				c.coreVersion = version.Version
				c.activeContent, c.activeSettings = content, s
				c.mu.Unlock()
				return nil
			}
		}
	}
}

func (c *Core) StartWithFD(ctx context.Context, content string, s Settings, fd int) error {
	if !c.InProcess {
		return errors.New("mobile core is not enabled")
	}
	if fd <= 0 {
		return errors.New("Android VPN descriptor is not available")
	}
	c.mu.Lock()
	c.fd = fd
	c.mu.Unlock()
	failed := true
	defer func() {
		if err := recover(); err != nil {
			c.recordError(fmt.Errorf("mobile core failed: %v", err))
		}
		if failed {
			c.mu.Lock()
			c.fd = 0
			c.mu.Unlock()
		}
	}()
	err := c.start(ctx, content, s, false)
	if err == nil {
		failed = false
	}
	return err
}

func (c *Core) startInProcess(ctx context.Context, content string, s Settings) error {
	C.SetHomeDir(c.Dir)
	if _, err := c.Validate(ctx, content, s, false); err != nil {
		return err
	}
	listener, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", fmt.Sprint(s.MixedPort)))
	if err != nil {
		return fmt.Errorf("proxy port %d is in use; stop the other proxy or choose another port", s.MixedPort)
	}
	_ = listener.Close()
	packet, err := net.ListenPacket("udp", net.JoinHostPort("127.0.0.1", fmt.Sprint(s.MixedPort)))
	if err != nil {
		return fmt.Errorf("proxy UDP port %d is unavailable; stop the other proxy or choose another port", s.MixedPort)
	}
	_ = packet.Close()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	address := l.Addr().String()
	l.Close()
	b, err := Runtime(content, s, address, c.Secret, c.Dir, false)
	if err != nil {
		return err
	}
	doc := yamlMap(b)
	tun, _ := doc["tun"].(map[string]any)
	if tun == nil {
		tun = map[string]any{}
	}
	c.mu.Lock()
	fd := c.fd
	include, exclude := c.includePackages, c.excludePackages
	c.mu.Unlock()
	applyMobileTunOptions(tun, fd, include, exclude)
	doc["tun"] = tun
	final, err := yaml.Marshal(doc)
	if err != nil {
		return err
	}
	logrus.SetOutput(coreLogWriter(c))
	if err = hub.Parse(final, hub.WithExternalController(address), hub.WithSecret(c.Secret)); err != nil {
		c.appendLog("Mobile core: " + err.Error())
		return err
	}
	runCtx, cancel := context.WithCancel(ctx)
	c.mu.Lock()
	c.Address = address
	c.running = true
	c.coreVersion = "mobile-" + CoreCommit[:7]
	c.lastError = ""
	c.activeContent, c.activeSettings = content, s
	c.done = make(chan struct{})
	c.runCancel = cancel
	c.mu.Unlock()
	go func() {
		<-runCtx.Done()
		_ = c.Stop()
	}()
	return nil
}

func startupTimeout(content []byte) time.Duration {
	var config struct {
		Proxies map[string]struct {
			Type string `yaml:"type"`
		} `yaml:"proxy-providers"`
		Rules map[string]struct {
			Type string `yaml:"type"`
		} `yaml:"rule-providers"`
	}
	if yaml.Unmarshal(content, &config) == nil {
		for _, providers := range []map[string]struct {
			Type string `yaml:"type"`
		}{config.Proxies, config.Rules} {
			for _, provider := range providers {
				if provider.Type == "http" {
					return 75 * time.Second
				}
			}
		}
	}
	return 15 * time.Second
}
func (c *Core) Stop() error {
	c.mu.Lock()
	if c.InProcess {
		if !c.running {
			c.mu.Unlock()
			return nil
		}
		c.running = false
		done := c.done
		cancel := c.runCancel
		c.runCancel = nil
		c.fd = 0
		c.mu.Unlock()
		if cancel != nil {
			cancel()
		}
		executor.Shutdown()
		// Shutdown only closes the TUN listener. The mixed proxy and DNS
		// server are owned by the core's listener/dns packages, so release
		// them explicitly or a reconnect fails with "proxy port in use".
		listener.ReCreateMixed(0, nil)
		dns.ReCreateServer("", nil, nil)
		if done != nil {
			close(done)
		}
		return nil
	}
	cmd, done := c.cmd, c.done
	if cmd != nil {
		c.stopping = true
	}
	c.mu.Unlock()
	var err error
	if cmd != nil {
		err = interruptCore(cmd)
		select {
		case <-done:
			err = nil
		case <-time.After(10 * time.Second):
			_ = cmd.Process.Kill()
			<-done
			err = nil
		}
	}
	if pe := c.restoreProxy(); pe != nil {
		err = pe
	}
	return err
}

func coreLogWriter(c *Core) io.Writer { return &coreWriter{core: c} }

type coreWriter struct{ core *Core }

func (w *coreWriter) Write(p []byte) (int, error) {
	w.core.appendLog(strings.TrimRight(string(p), "\r\n"))
	return len(p), nil
}

func yamlMap(value []byte) map[string]any {
	var doc map[string]any
	_ = yaml.Unmarshal(value, &doc)
	return doc
}
func (c *Core) restoreProxy() error {
	c.proxyMu.Lock()
	defer c.proxyMu.Unlock()
	if c.proxy != nil {
		if pe := RestoreProxy(*c.proxy); pe != nil {
			return pe
		} else {
			c.proxy = nil
			_ = os.Remove(filepath.Join(c.Dir, "proxy-backup.json"))
		}
	}
	return nil
}
func (c *Core) Apply(ctx context.Context, content string, s Settings, privileged bool) error {
	if _, err := c.Validate(ctx, content, s, privileged); err != nil {
		return err
	}
	if c.InProcess {
		C.SetHomeDir(c.Dir)
		if !c.Status().Running {
			return nil
		}
		listener, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", fmt.Sprint(s.MixedPort)))
		if err != nil {
			return fmt.Errorf("proxy port %d is in use; stop the other proxy or choose another port", s.MixedPort)
		}
		_ = listener.Close()
		b, err := Runtime(content, s, c.Address, c.Secret, c.Dir, privileged)
		if err != nil {
			return err
		}
		doc := yamlMap(b)
		tun, _ := doc["tun"].(map[string]any)
		if tun == nil {
			tun = map[string]any{}
		}
		c.mu.Lock()
		fd := c.fd
		include, exclude := c.includePackages, c.excludePackages
		c.mu.Unlock()
		applyMobileTunOptions(tun, fd, include, exclude)
		doc["tun"] = tun
		final, err := yaml.Marshal(doc)
		if err != nil {
			return err
		}
		if err = hub.Parse(final, hub.WithExternalController(c.Address), hub.WithSecret(c.Secret)); err != nil {
			return err
		}
		c.mu.Lock()
		c.activeContent, c.activeSettings = content, s
		c.mu.Unlock()
		return nil
	}
	if !c.Status().Running {
		return nil
	}
	b, err := Runtime(content, s, c.Address, c.Secret, c.Dir, privileged)
	if err != nil {
		return err
	}
	previous, err := os.ReadFile(filepath.Join(c.Dir, "runtime.yaml"))
	if err != nil {
		return err
	}
	_, err = c.Request(ctx, "PUT", "/configs?force=true", map[string]any{"payload": string(b)})
	if err != nil {
		_, restoreErr := c.Request(ctx, "PUT", "/configs?force=true", map[string]any{"payload": string(previous)})
		if restoreErr != nil {
			_ = c.Stop()
			return fmt.Errorf("configuration failed and could not be restored; proxy stopped: %w", err)
		}
		return err
	}
	if err = AtomicWrite(filepath.Join(c.Dir, "runtime.yaml"), b, 0600); err != nil {
		_, _ = c.Request(ctx, "PUT", "/configs?force=true", map[string]any{"payload": string(previous)})
		return err
	}
	c.mu.Lock()
	c.activeContent, c.activeSettings = content, s
	c.mu.Unlock()
	return nil
}
func (c *Core) Request(ctx context.Context, method, path string, body any) (json.RawMessage, error) {
	u, err := url.Parse(path)
	if err != nil || u.Host != "" || !strings.HasPrefix(path, "/") {
		return nil, errors.New("invalid controller request")
	}
	b, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, method, "http://"+c.Address+path, bytes.NewReader(b))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.Secret)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.client.Do(req)
	if err != nil {
		return nil, errors.New("core is not reachable; reconnect to try again")
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, MaxConfig+1))
	if err != nil {
		return nil, err
	}
	if len(data) > MaxConfig {
		return nil, errors.New("controller response too large")
	}
	if resp.StatusCode >= 300 {
		return nil, fmt.Errorf("core returned %d: %s", resp.StatusCode, bounded(string(data), 1800))
	}
	if len(data) == 0 {
		data = []byte("null")
	}
	return data, nil
}
func (c *Core) EnableProxy(port int) error {
	return c.enableProxy(port, true)
}
func (c *Core) ProxyEnabled() bool { c.proxyMu.Lock(); defer c.proxyMu.Unlock(); return c.proxy != nil }
func (c *Core) enableProxy(port int, requireRunning bool) error {
	c.proxyMu.Lock()
	defer c.proxyMu.Unlock()
	if requireRunning && !c.Status().Running {
		return errors.New("core stopped before proxy setup; reconnect to try again")
	}
	if c.proxy != nil {
		return nil
	}
	snapshot, err := CaptureProxy(port)
	if err != nil {
		return err
	}
	b, _ := json.Marshal(snapshot)
	if err = AtomicWrite(filepath.Join(c.Dir, "proxy-backup.json"), b, 0600); err != nil {
		return err
	}
	c.proxy = &snapshot
	if err = SetProxy(snapshot); err != nil {
		if restoreErr := RestoreProxy(snapshot); restoreErr == nil {
			c.proxy = nil
			_ = os.Remove(filepath.Join(c.Dir, "proxy-backup.json"))
		}
		return err
	}
	return nil
}
func (c *Core) RecoverProxy() error {
	b, err := os.ReadFile(filepath.Join(c.Dir, "proxy-backup.json"))
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	var p ProxySnapshot
	if err = json.Unmarshal(b, &p); err != nil {
		return err
	}
	if err = RestoreProxy(p); err != nil {
		return err
	}
	return os.Remove(filepath.Join(c.Dir, "proxy-backup.json"))
}
func bounded(s string, n int) string {
	if len(s) > n {
		return s[len(s)-n:]
	}
	return s
}
