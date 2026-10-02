package desktop

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestChecksumRequiresNamedMatchingAsset(t *testing.T) {
	data := []byte("candidate")
	sum := sha256.Sum256(data)
	manifest := []byte(fmt.Sprintf("%x  ./core.zip\n", sum))
	if err := VerifyChecksum(data, manifest, "core.zip"); err != nil {
		t.Fatal(err)
	}
	if VerifyChecksum([]byte("corrupt"), manifest, "core.zip") == nil {
		t.Fatal("corrupt core accepted")
	}
	if VerifyChecksum(data, manifest, "other.zip") == nil {
		t.Fatal("missing core accepted")
	}
}
func TestZipExtractionDoesNotWritePaths(t *testing.T) {
	var b bytes.Buffer
	w := zip.NewWriter(&b)
	f, _ := w.Create("../../aster-core-test.exe")
	_, _ = f.Write([]byte("test"))
	_ = w.Close()
	out, err := ExtractCore(b.Bytes(), "test.zip")
	if err != nil || string(out) != "test" {
		t.Fatal(err)
	}
	if CheckArchitecture(out, "windows", "amd64") == nil {
		t.Fatal("invalid binary accepted")
	}
}
func TestSubscriptionFailureAndLimits(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/fail":
			w.WriteHeader(500)
		case "/large":
			_, _ = w.Write([]byte(strings.Repeat("x", MaxConfig+1)))
		default:
			w.Header().Set("Subscription-Userinfo", "upload=0; download=100; total=200")
			_, _ = w.Write([]byte("proxies: []\nrules: [MATCH,DIRECT]\n"))
		}
	}))
	defer server.Close()
	ctx := context.Background()
	if _, _, err := FetchSubscription(ctx, server.URL+"/fail"); err == nil {
		t.Fatal("HTTP error ignored")
	}
	if _, _, err := FetchSubscription(ctx, server.URL+"/large"); err == nil {
		t.Fatal("large download accepted")
	}
	if data, usage, err := FetchSubscription(ctx, server.URL); err != nil || data == "" || usage == "" {
		t.Fatalf("successful fetch failed: %v", err)
	}
}
func TestAtomicStoreRoundTrip(t *testing.T) {
	dir := t.TempDir()
	s, err := OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	s.State.Profiles = append(s.State.Profiles, Profile{ID: "test", Name: "Original", Content: "proxies: []"})
	s.State.ActiveID = "test"
	if err = s.Save(); err != nil {
		t.Fatal(err)
	}
	again, err := OpenStore(dir)
	if err != nil || again.State.ActiveID != "test" || len(again.State.Profiles) != 1 {
		t.Fatalf("round trip: %v", err)
	}
}

func TestOnlyOneDesktopOwnsUserData(t *testing.T) {
	dir := t.TempDir()
	first, err := NewApp(dir, "unused", "")
	if err != nil {
		t.Fatal(err)
	}
	if second, err := NewApp(dir, "unused", ""); err == nil {
		second.Close()
		t.Fatal("a second manager could change the same user proxy")
	}
	_ = first.Close()
	next, err := NewApp(dir, "unused", "")
	if err != nil {
		t.Fatal("lock was not released on exit:", err)
	}
	defer next.Close()
}
