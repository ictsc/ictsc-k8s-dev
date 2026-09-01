package provider

import (
	_ "embed"
	"errors"
	"fmt"
	"net"
	"strconv"
)

var ID = "sakura"

//go:embed assets/icon.svg
var Icon []byte

//go:embed assets/schema.json
var MachineClassSchema string

type MachineClass struct {
	Zone             string   `yaml:"zone" json:"zone"`
	ArchiveID        string   `yaml:"archive_id" json:"archive_id"`
	CPU              int      `yaml:"cpu" json:"cpu"`
	MemoryGiB        int      `yaml:"memory_gib" json:"memory_gib"`
	DiskGiB          int      `yaml:"disk_gib" json:"disk_gib"`
	DataDiskGiB      int      `yaml:"data_disk_gib" json:"data_disk_gib"`
	ExternalSwitchID string   `yaml:"external_switch_id" json:"external_switch_id"`
	ExternalIPPool   []string `yaml:"external_ip_pool" json:"external_ip_pool"`
	ExternalGateway  string   `yaml:"external_gateway" json:"external_gateway"`
	ExternalNetmask  int      `yaml:"external_netmask" json:"external_netmask"`
	PacketFilterID   string   `yaml:"packet_filter_id" json:"packet_filter_id"`
	InternalSwitchID string   `yaml:"internal_switch_id" json:"internal_switch_id"`
	InternalIPPool   []string `yaml:"internal_ip_pool" json:"internal_ip_pool"`
	InternalNetmask  int      `yaml:"internal_netmask" json:"internal_netmask"`
	Nameservers      []string `yaml:"nameservers" json:"nameservers"`
}

func mergeMachineClass(defaults, configured MachineClass) MachineClass {
	result := defaults
	if configured.Zone != "" {
		result.Zone = configured.Zone
	}
	if configured.ArchiveID != "" {
		result.ArchiveID = configured.ArchiveID
	}
	if configured.CPU != 0 {
		result.CPU = configured.CPU
	}
	if configured.MemoryGiB != 0 {
		result.MemoryGiB = configured.MemoryGiB
	}
	if configured.DiskGiB != 0 {
		result.DiskGiB = configured.DiskGiB
	}
	if configured.DataDiskGiB != 0 {
		result.DataDiskGiB = configured.DataDiskGiB
	}
	if configured.ExternalSwitchID != "" {
		result.ExternalSwitchID = configured.ExternalSwitchID
	}
	if len(configured.ExternalIPPool) != 0 {
		result.ExternalIPPool = configured.ExternalIPPool
	}
	if configured.ExternalGateway != "" {
		result.ExternalGateway = configured.ExternalGateway
	}
	if configured.ExternalNetmask != 0 {
		result.ExternalNetmask = configured.ExternalNetmask
	}
	if configured.PacketFilterID != "" {
		result.PacketFilterID = configured.PacketFilterID
	}
	if configured.InternalSwitchID != "" {
		result.InternalSwitchID = configured.InternalSwitchID
	}
	if len(configured.InternalIPPool) != 0 {
		result.InternalIPPool = configured.InternalIPPool
	}
	if configured.InternalNetmask != 0 {
		result.InternalNetmask = configured.InternalNetmask
	}
	if len(configured.Nameservers) != 0 {
		result.Nameservers = configured.Nameservers
	}
	return result
}

func (m MachineClass) Validate() error {
	var errs []error
	if m.Zone == "" {
		errs = append(errs, errors.New("zone is required"))
	}
	for name, value := range map[string]string{
		"archive_id": m.ArchiveID, "external_switch_id": m.ExternalSwitchID,
		"internal_switch_id": m.InternalSwitchID,
	} {
		if _, err := strconv.ParseInt(value, 10, 64); value == "" || err != nil {
			errs = append(errs, fmt.Errorf("%s must be a Sakura Cloud numeric ID", name))
		}
	}
	if m.PacketFilterID != "" {
		if _, err := strconv.ParseInt(m.PacketFilterID, 10, 64); err != nil {
			errs = append(errs, errors.New("packet_filter_id must be a Sakura Cloud numeric ID"))
		}
	}
	if m.CPU < 1 {
		errs = append(errs, errors.New("cpu must be at least 1"))
	}
	if m.MemoryGiB < 1 {
		errs = append(errs, errors.New("memory_gib must be at least 1"))
	}
	if m.DiskGiB < 20 {
		errs = append(errs, errors.New("disk_gib must be at least 20"))
	}
	if m.DataDiskGiB != 0 && m.DataDiskGiB < 20 {
		errs = append(errs, errors.New("data_disk_gib must be zero or at least 20"))
	}
	if m.ExternalNetmask < 1 || m.ExternalNetmask > 32 {
		errs = append(errs, errors.New("external_netmask must be between 1 and 32"))
	}
	if m.InternalNetmask < 1 || m.InternalNetmask > 32 {
		errs = append(errs, errors.New("internal_netmask must be between 1 and 32"))
	}
	validateIPs := func(name string, values []string, required bool) {
		if required && len(values) == 0 {
			errs = append(errs, fmt.Errorf("%s is required", name))
			return
		}
		seen := map[string]struct{}{}
		for _, value := range values {
			ip := net.ParseIP(value)
			if ip == nil || ip.To4() == nil {
				errs = append(errs, fmt.Errorf("%s contains invalid IPv4 address %q", name, value))
			}
			if _, ok := seen[value]; ok {
				errs = append(errs, fmt.Errorf("%s contains duplicate address %q", name, value))
			}
			seen[value] = struct{}{}
		}
	}
	validateIPs("external_ip_pool", m.ExternalIPPool, true)
	validateIPs("internal_ip_pool", m.InternalIPPool, true)
	validateIPs("nameservers", m.Nameservers, true)
	validateIPs("external_gateway", []string{m.ExternalGateway}, true)
	if len(m.ExternalIPPool) != len(m.InternalIPPool) {
		errs = append(errs, errors.New("external_ip_pool and internal_ip_pool must have the same length"))
	}
	return errors.Join(errs...)
}
