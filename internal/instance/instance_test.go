package instance

import (
	"context"
	"os"
	"os/exec"
	"testing"
	"time"
)

func TestSecondLaunchActivatesOwner(t *testing.T) {
	if child := os.Getenv("ASTER_INSTANCE_CHILD"); child != "" {
		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
		defer cancel()
		lease, err := Acquire(ctx, child, func() bool { return false })
		if err != nil {
			t.Fatal(err)
		}
		if lease != nil {
			lease.Close()
			t.Fatal("second process acquired the live lease")
		}
		return
	}
	dir := t.TempDir()
	activated := make(chan struct{}, 1)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	owner, err := Acquire(ctx, dir, func() bool { activated <- struct{}{}; return true })
	if err != nil || owner == nil {
		t.Fatalf("first launch: lease %v, error %v", owner, err)
	}
	defer owner.Close()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestSecondLaunchActivatesOwner$")
	cmd.Env = append(os.Environ(), "ASTER_INSTANCE_CHILD="+dir)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("second launch: %v\n%s", err, output)
	}
	select {
	case <-activated:
	default:
		t.Fatal("second launch did not activate the owner")
	}
}
