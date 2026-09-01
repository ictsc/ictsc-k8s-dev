package main

import (
	"context"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/ictsc/ictsc-k8s-dev/omni/infra-provider-sakura/internal/provider"
	"github.com/sacloud/iaas-api-go"
	"github.com/siderolabs/omni/client/pkg/client"
	"github.com/siderolabs/omni/client/pkg/infra"
	"go.uber.org/zap"
)

var version = "dev"

type config struct {
	omniEndpoint string
	omniKey      string
	providerID   string
	zone         string
	configFile   string
}

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if err := run(ctx); err != nil {
		log.Fatal(err)
	}
}

func run(ctx context.Context) error {
	cfg := config{}
	flag.StringVar(&cfg.omniEndpoint, "omni-api-endpoint", os.Getenv("OMNI_ENDPOINT"), "Omni API endpoint")
	flag.StringVar(&cfg.omniKey, "omni-service-account-key", os.Getenv("OMNI_SERVICE_ACCOUNT_KEY"), "Omni infrastructure provider key")
	flag.StringVar(&cfg.providerID, "id", "sakura", "unique Omni infrastructure provider ID")
	flag.StringVar(&cfg.zone, "health-check-zone", envOr("SAKURACLOUD_ZONE", "tk1b"), "zone used by provider health checks")
	flag.StringVar(&cfg.configFile, "config-file", envOr("SAKURA_PROVIDER_CONFIG", "/etc/omni/sakura-provider.yaml"), "provider defaults YAML")
	flag.Parse()
	if cfg.omniEndpoint == "" || cfg.omniKey == "" {
		return errors.New("OMNI_ENDPOINT and OMNI_SERVICE_ACCOUNT_KEY are required")
	}

	logger, err := zap.NewProduction()
	if err != nil {
		return err
	}
	defer func() { _ = logger.Sync() }()
	cloud := provider.NewSakuraCloud(iaas.NewClientFromEnv())
	config, err := provider.LoadConfig(cfg.configFile)
	if err != nil {
		return err
	}
	defaults, err := cloud.EnsureInfrastructure(ctx, cfg.zone, config.Bootstrap, config.Defaults)
	if err != nil {
		return fmt.Errorf("ensure Sakura infrastructure: %w", err)
	}
	provisioner := provider.NewProvisioner(cloud, defaults)
	provider.ID = cfg.providerID
	ip, err := infra.NewProvider(provider.ID, provisioner, infra.ProviderConfig{
		Name: "Sakura Cloud", Description: "Dynamically provisions Talos machines on Sakura Cloud.",
		Icon: base64.RawStdEncoding.EncodeToString(provider.Icon), Schema: provider.MachineClassSchema,
	})
	if err != nil {
		return fmt.Errorf("create infrastructure provider: %w", err)
	}
	return ip.Run(ctx, logger,
		infra.WithOmniEndpoint(cfg.omniEndpoint),
		infra.WithClientOptions(client.WithServiceAccount(cfg.omniKey)),
		infra.WithEncodeRequestIDsIntoTokens(),
		infra.WithConcurrency(1),
		infra.WithHealthCheckFunc(func(ctx context.Context) error { return cloud.Health(ctx, cfg.zone) }),
	)
}

func envOr(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
