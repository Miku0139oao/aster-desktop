package desktop

import (
	"os"
	"path/filepath"
	"testing"
)

func TestMissingGeoSiteListMatchesCoreOutput(t *testing.T) {
	output := `time="2026-11-22T01:04:26.448470600+08:00" level=error msg="load GeoSite data error, failed to decode geodata file: GeoSite.dat, base error: list geolocation-!cn not found in GeoSite.dat"`
	if !missingGeoSiteList(output) {
		t.Fatal("expected a missing GeoSite list to be recognized")
	}
	if missingGeoSiteList("configuration validation failed: exit status 1\nproxy 0: invalid") {
		t.Fatal("an unrelated failure must not be treated as a stale geodata cache")
	}
}

func TestRetireGeoSiteCacheMovesTheFileAside(t *testing.T) {
	dir := t.TempDir()
	// The core accepts any case variant of the name, so the cleanup must too.
	path := filepath.Join(dir, "geosite.dat")
	if err := os.WriteFile(path, []byte("stale"), 0o600); err != nil {
		t.Fatal(err)
	}
	core := NewCore("", dir)
	if !core.retireGeoSiteCache() {
		t.Fatal("expected the cached database to be retired")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("expected %s to be gone, got %v", path, err)
	}
	if _, err := os.Stat(path + ".stale"); err != nil {
		t.Fatalf("expected the retired copy to remain: %v", err)
	}
	if core.retireGeoSiteCache() {
		t.Fatal("retiring must report false once no database is left")
	}
}

func TestRetireGeoSiteCacheWithoutDatabase(t *testing.T) {
	core := NewCore("", t.TempDir())
	if core.retireGeoSiteCache() {
		t.Fatal("a directory without GeoSite.dat has nothing to retire")
	}
}
