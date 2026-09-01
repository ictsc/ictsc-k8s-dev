package provider

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

func buildCIDATA(ctx context.Context, instanceID string, userData []byte) (string, func(), error) {
	dir, err := os.MkdirTemp("", "omni-sakura-cidata-")
	if err != nil {
		return "", nil, fmt.Errorf("create cidata temp directory: %w", err)
	}
	cleanup := func() { _ = os.RemoveAll(dir) }
	sourceDir := filepath.Join(dir, "source")
	if err := os.Mkdir(sourceDir, 0o700); err != nil {
		cleanup()
		return "", nil, err
	}
	if err := os.WriteFile(filepath.Join(sourceDir, "user-data"), userData, 0o600); err != nil {
		cleanup()
		return "", nil, err
	}
	if err := os.WriteFile(filepath.Join(sourceDir, "meta-data"), []byte("instance-id: "+instanceID+"\n"), 0o600); err != nil {
		cleanup()
		return "", nil, err
	}
	out := filepath.Join(dir, "cidata.iso")
	cmd := exec.CommandContext(ctx, "xorrisofs", "-quiet", "-output", out, "-volid", "cidata", "-joliet", "-rational-rock", sourceDir)
	if output, err := cmd.CombinedOutput(); err != nil {
		cleanup()
		return "", nil, fmt.Errorf("build cidata ISO: %w: %s", err, output)
	}
	return out, cleanup, nil
}
