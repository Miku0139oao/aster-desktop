//go:build ios

package desktop

import "context"

func installedApplications(context.Context) ([]Application, error) {
	return []Application{}, nil
}

func applicationPaths(context.Context) ([]string, error) {
	return []string{}, nil
}

func describeApplication(path string) Application {
	return Application{Name: path, Path: path, Installed: true}
}

func CaptureProxy(int) (ProxySnapshot, error) {
	return ProxySnapshot{}, nil
}

func SetProxy(ProxySnapshot) error { return nil }

func RestoreProxy(ProxySnapshot) error { return nil }

func PrepareDownloadedCore(string) error { return nil }
