package provider

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

// Config contains defaults shared by MachineClasses. Keeping these values in a
// root-owned file makes Terraform optional; MachineClasses only need sizing and
// role-specific overrides.
type Config struct {
	Defaults  MachineClass    `yaml:"defaults"`
	Bootstrap BootstrapConfig `yaml:"bootstrap"`
}

// BootstrapConfig controls idempotent creation of shared Sakura resources.
// Existing IDs in defaults always take precedence, so Terraform-created
// environments remain compatible.
type BootstrapConfig struct {
	Enabled            bool   `yaml:"enabled"`
	InternetName       string `yaml:"internet_name"`
	InternetMask       int    `yaml:"internet_mask"`
	InternetBandwidth  int    `yaml:"internet_bandwidth_mbps"`
	ExternalIPCount    int    `yaml:"external_ip_count"`
	InternalSwitchName string `yaml:"internal_switch_name"`
	InternalCIDRMask   int    `yaml:"internal_cidr_mask"`
	PacketFilterName   string `yaml:"packet_filter_name"`
	SourceArchiveID    string `yaml:"source_archive_id"`
	ArchiveName        string `yaml:"archive_name"`
}

func LoadConfig(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("read provider config: %w", err)
	}
	var config Config
	if err := yaml.Unmarshal(data, &config); err != nil {
		return Config{}, fmt.Errorf("parse provider config: %w", err)
	}
	if !config.Bootstrap.Enabled {
		if err := config.Defaults.Validate(); err != nil {
			return Config{}, fmt.Errorf("invalid provider defaults: %w", err)
		}
	}
	return config, nil
}
