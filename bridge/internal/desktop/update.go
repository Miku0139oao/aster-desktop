package desktop

import (
	"archive/zip"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"debug/elf"
	"debug/macho"
	"debug/pe"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const coreReleaseAPI = "https://api.github.com/repos/Miku0139oao/aster-core/releases/tags/Prerelease-main"

type ReleaseAsset struct {
	Name string `json:"name"`
	URL  string `json:"browser_download_url"`
}
type Release struct {
	Tag    string         `json:"tag_name"`
	URL    string         `json:"html_url"`
	Assets []ReleaseAsset `json:"assets"`
}

func fetch(ctx context.Context, address string, limit int64) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, "GET", address, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "AsterDesktop/"+Version)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("download server returned %d", resp.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > limit {
		return nil, errors.New("download exceeds size limit")
	}
	return b, nil
}
func release(ctx context.Context, address string) (Release, error) {
	b, err := fetch(ctx, address, 1<<20)
	if err != nil {
		return Release{}, err
	}
	var r Release
	err = json.Unmarshal(b, &r)
	return r, err
}
func CheckUpdates(ctx context.Context) (any, error) {
	r, err := release(ctx, coreReleaseAPI)
	if err != nil {
		return nil, err
	}
	guiURL := "https://github.com/Miku0139oao/aster-desktop/releases"
	result := map[string]any{"core": r, "desktopVersion": Version}
	if gui, e := release(ctx, "https://api.github.com/repos/Miku0139oao/aster-desktop/releases/latest"); e == nil {
		result["gui"] = gui
		result["guiUrl"] = guiURL
	}
	return result, nil
}
func assetPrefix() string {
	arch := runtime.GOARCH
	if arch == "amd64" {
		arch = "amd64-v1"
	}
	return "aster-core-" + runtime.GOOS + "-" + arch + "-"
}
func chooseAsset(r Release) (ReleaseAsset, ReleaseAsset, error) {
	var pkg, checksum ReleaseAsset
	suffix := ".gz"
	if runtime.GOOS == "windows" {
		suffix = ".zip"
	}
	for _, a := range r.Assets {
		if a.Name == "checksums.txt" {
			checksum = a
		}
		if strings.HasPrefix(a.Name, assetPrefix()) && strings.HasSuffix(a.Name, suffix) {
			pkg = a
		}
	}
	if pkg.URL == "" || checksum.URL == "" {
		return pkg, checksum, errors.New("release does not contain a core and checksums for this computer")
	}
	for _, a := range []ReleaseAsset{pkg, checksum} {
		if !strings.HasPrefix(a.URL, "https://github.com/Miku0139oao/aster-core/releases/download/Prerelease-main/") {
			return pkg, checksum, errors.New("untrusted core release source")
		}
	}
	return pkg, checksum, nil
}
func VerifyChecksum(data, manifest []byte, name string) error {
	sum := sha256.Sum256(data)
	expected := hex.EncodeToString(sum[:])
	for _, line := range strings.Split(string(manifest), "\n") {
		parts := strings.Fields(line)
		if len(parts) == 2 && strings.TrimPrefix(strings.TrimPrefix(parts[1], "*"), "./") == name {
			if !strings.EqualFold(parts[0], expected) {
				return errors.New("core checksum does not match; existing core kept")
			}
			return nil
		}
	}
	return errors.New("core is missing from the checksum manifest")
}
func ExtractCore(pkg []byte, name string) ([]byte, error) {
	if strings.HasSuffix(name, ".zip") {
		z, err := zip.NewReader(bytes.NewReader(pkg), int64(len(pkg)))
		if err != nil {
			return nil, err
		}
		for _, f := range z.File {
			if !f.FileInfo().IsDir() && strings.HasSuffix(f.Name, ".exe") && strings.HasPrefix(filepath.Base(f.Name), "aster-core-") {
				if f.UncompressedSize64 > 128<<20 {
					return nil, errors.New("expanded core too large")
				}
				r, err := f.Open()
				if err != nil {
					return nil, err
				}
				defer r.Close()
				b, err := io.ReadAll(io.LimitReader(r, 128<<20+1))
				if len(b) > 128<<20 {
					return nil, errors.New("expanded core too large")
				}
				return b, err
			}
		}
		return nil, errors.New("no core executable in package")
	}
	r, err := gzip.NewReader(bytes.NewReader(pkg))
	if err != nil {
		return nil, err
	}
	defer r.Close()
	b, err := io.ReadAll(io.LimitReader(r, 128<<20+1))
	if len(b) > 128<<20 {
		return nil, errors.New("expanded core too large")
	}
	return b, err
}
func CheckArchitecture(data []byte, goos, arch string) error {
	r := bytes.NewReader(data)
	switch goos {
	case "windows":
		f, err := pe.NewFile(r)
		if err != nil {
			return err
		}
		defer f.Close()
		if arch == "amd64" && f.Machine == pe.IMAGE_FILE_MACHINE_AMD64 {
			return nil
		}
	case "linux":
		f, err := elf.NewFile(r)
		if err != nil {
			return err
		}
		defer f.Close()
		if arch == "amd64" && f.Machine == elf.EM_X86_64 {
			return nil
		}
	case "darwin":
		f, err := macho.NewFile(r)
		if err != nil {
			return err
		}
		defer f.Close()
		if arch == "amd64" && f.Cpu == macho.CpuAmd64 || arch == "arm64" && f.Cpu == macho.CpuArm64 {
			return nil
		}
	}
	return errors.New("downloaded core has the wrong architecture")
}
func (a *App) UpdateCore(ctx context.Context) (any, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	a.Emit("updateProgress", "download")
	r, err := release(ctx, coreReleaseAPI)
	if err != nil {
		return nil, err
	}
	asset, checks, err := chooseAsset(r)
	if err != nil {
		return nil, err
	}
	manifest, err := fetch(ctx, checks.URL, 1<<20)
	if err != nil {
		return nil, err
	}
	pkg, err := fetch(ctx, asset.URL, 64<<20)
	if err != nil {
		return nil, err
	}
	if err = VerifyChecksum(pkg, manifest, asset.Name); err != nil {
		return nil, err
	}
	data, err := ExtractCore(pkg, asset.Name)
	if err != nil {
		return nil, err
	}
	if err = CheckArchitecture(data, runtime.GOOS, runtime.GOARCH); err != nil {
		return nil, err
	}
	dir := filepath.Join(a.Store.Dir, "cores")
	if err = os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	name := "aster-core"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	candidate := filepath.Join(dir, RandomID()+"-"+name)
	if err = AtomicWrite(candidate, data, 0700); err != nil {
		return nil, err
	}
	accepted := false
	defer func() {
		if !accepted {
			_ = os.Remove(candidate)
		}
	}()
	if err = PrepareDownloadedCore(candidate); err != nil {
		return nil, err
	}
	a.Emit("updateProgress", "verify")
	tmp, err := os.MkdirTemp(a.Store.Dir, "compat-*")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(tmp)
	probe := NewCore(candidate, tmp)
	s := DefaultSettings()
	s.SystemProxy = false
	s.MixedPort = unusedPort()
	minimal := "proxies: []\nrules:\n  - MATCH,DIRECT\n"
	if err = probe.Start(ctx, minimal, s, false); err != nil {
		return nil, err
	}
	defer probe.Stop()
	for _, endpoint := range []string{"/version", "/configs", "/proxies", "/rules", "/connections"} {
		body, err := probe.Request(ctx, "GET", endpoint, nil)
		if err != nil {
			return nil, fmt.Errorf("new core is incompatible: %w", err)
		}
		var value map[string]any
		if json.Unmarshal(body, &value) != nil {
			return nil, errors.New("new core returned an incompatible API response")
		}
		required := map[string]string{"/version": "version", "/configs": "mode", "/proxies": "proxies", "/rules": "rules", "/connections": "connections"}[endpoint]
		if _, ok := value[required]; !ok {
			return nil, fmt.Errorf("new core is missing required API field %s", required)
		}
	}
	_ = probe.Stop()
	profile, err := a.Store.Profile(a.Store.State.ActiveID)
	if err == nil {
		check := NewCore(candidate, filepath.Join(a.Store.Dir, "validation"))
		if _, err = check.Validate(ctx, profile.Content, a.Store.State.Settings, a.Privileged); err != nil {
			return nil, err
		}
	}
	wasRunning := a.Core.Status().Running
	proxyWasEnabled := a.Core.ProxyEnabled()
	oldBinary := a.Core.Binary
	restorePrevious := func() error {
		rollbackCtx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
		defer cancel()
		_ = a.Core.Stop()
		a.Core.Binary = oldBinary
		if wasRunning {
			if err := a.Core.Start(rollbackCtx, profile.Content, a.Store.State.Settings, false); err != nil {
				return err
			}
			if proxyWasEnabled {
				if err := a.Core.EnableProxy(a.Store.State.Settings.MixedPort); err != nil {
					return err
				}
			}
			a.beginStreams()
			a.restoreSelections(rollbackCtx)
		}
		return nil
	}
	if err = a.Core.Stop(); err != nil {
		return nil, fmt.Errorf("cannot safely stop the current core: %w", err)
	}
	a.Core.Binary = candidate
	if wasRunning {
		if err = a.Core.Start(ctx, profile.Content, a.Store.State.Settings, false); err == nil && proxyWasEnabled {
			err = a.Core.EnableProxy(a.Store.State.Settings.MixedPort)
		}
		if err != nil {
			restartErr := restorePrevious()
			if restartErr != nil {
				return nil, fmt.Errorf("update failed; reconnect after checking configuration: %w", err)
			}
			return nil, fmt.Errorf("update failed; previous core restored: %w", err)
		}
	}
	selection := map[string]string{"active": candidate, "previous": oldBinary, "asset": asset.Name}
	b, _ := json.Marshal(selection)
	if err = AtomicWrite(filepath.Join(dir, "selection.json"), b, 0600); err != nil {
		if rollbackErr := restorePrevious(); rollbackErr != nil {
			return nil, fmt.Errorf("selection could not be saved and restart failed: %w", rollbackErr)
		}
		return nil, err
	}
	accepted = true
	if wasRunning {
		a.beginStreams()
		a.restoreSelections(ctx)
	}
	a.Emit("updateProgress", "complete")
	return selection, nil
}

func (a *App) restoreSelections(ctx context.Context) {
	for group, node := range a.Store.State.Selections {
		_, _ = a.dispatchCore(ctx, "PUT", "/proxies/"+url.PathEscape(group), map[string]string{"name": node})
	}
}
