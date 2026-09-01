package provider

import (
	"context"
	"fmt"
	"net"
	"strconv"

	"github.com/sacloud/iaas-api-go"
	"github.com/sacloud/iaas-api-go/helper/cleanup"
	"github.com/sacloud/iaas-api-go/helper/power"
	"github.com/sacloud/iaas-api-go/helper/query"
	"github.com/sacloud/iaas-api-go/types"
	cdromsvc "github.com/sacloud/iaas-service-go/cdrom"
	diskbuilder "github.com/sacloud/iaas-service-go/disk/builder"
	serverbuilder "github.com/sacloud/iaas-service-go/server/builder"
)

type MachineResources struct {
	ServerID string
	DiskIDs  []string
}

type CreateMachineRequest struct {
	Name       string
	Class      MachineClass
	ExternalIP string
	InternalIP string
	CDROMID    string
}

type Cloud interface {
	UsedIPs(context.Context, string) ([]string, error)
	CreateCDROM(context.Context, string, string, string) (string, error)
	CreateMachine(context.Context, CreateMachineRequest) (MachineResources, error)
	DeleteMachine(context.Context, string, string, []string, string) error
	Health(context.Context, string) error
}

type SakuraCloud struct{ client iaas.APICaller }

func NewSakuraCloud(client iaas.APICaller) *SakuraCloud { return &SakuraCloud{client: client} }

// EnsureInfrastructure creates the shared Internet, vSwitch and packet filter
// when they are absent. It is deliberately additive: resources are found by
// name and never deleted or mutated, making repeated provider restarts safe.
func (c *SakuraCloud) EnsureInfrastructure(ctx context.Context, zone string, b BootstrapConfig, defaults MachineClass) (MachineClass, error) {
	if !b.Enabled {
		return defaults, nil
	}
	if b.InternetName == "" {
		b.InternetName = "sakura-omni-internet"
	}
	if b.InternalSwitchName == "" {
		b.InternalSwitchName = "sakura-omni-internal"
	}
	if b.PacketFilterName == "" {
		b.PacketFilterName = "sakura-omni-filter"
	}
	if b.InternetMask == 0 {
		b.InternetMask = 27
	}
	if b.InternetBandwidth == 0 {
		b.InternetBandwidth = 100
	}
	if b.InternalCIDRMask == 0 {
		b.InternalCIDRMask = 24
	}

	out := defaults
	internetOp := iaas.NewInternetOp(c.client)
	ir, err := internetOp.Find(ctx, zone, nil)
	if err != nil {
		return out, err
	}
	var internet *iaas.Internet
	for _, v := range ir.Internet {
		if v.Name == b.InternetName {
			internet = v
			break
		}
	}
	if internet == nil {
		internet, err = internetOp.Create(ctx, zone, &iaas.InternetCreateRequest{Name: b.InternetName, NetworkMaskLen: b.InternetMask, BandWidthMbps: b.InternetBandwidth, Tags: types.Tags{"omni-managed=sakura"}})
		if err != nil {
			return out, fmt.Errorf("create internet: %w", err)
		}
		internet, err = internetOp.Read(ctx, zone, internet.ID)
		if err != nil {
			return out, fmt.Errorf("read internet: %w", err)
		}
	}
	if out.ExternalSwitchID == "" {
		out.ExternalSwitchID = internet.Switch.ID.String()
	}
	if len(out.ExternalIPPool) == 0 && internet.Switch != nil && len(internet.Switch.Subnets) > 0 {
		s := internet.Switch.Subnets[0]
		out.ExternalGateway = s.DefaultRoute
		out.ExternalNetmask = s.NetworkMaskLen
		out.ExternalIPPool = usableIPv4s(s.NetworkAddress, s.NetworkMaskLen, b.ExternalIPCount)
	}

	switchOp := iaas.NewSwitchOp(c.client)
	sr, err := switchOp.Find(ctx, zone, nil)
	if err != nil {
		return out, err
	}
	var sw *iaas.Switch
	for _, v := range sr.Switches {
		if v.Name == b.InternalSwitchName {
			sw = v
			break
		}
	}
	if sw == nil {
		sw, err = switchOp.Create(ctx, zone, &iaas.SwitchCreateRequest{Name: b.InternalSwitchName, NetworkMaskLen: b.InternalCIDRMask, Tags: types.Tags{"omni-managed=sakura"}})
		if err != nil {
			return out, fmt.Errorf("create switch: %w", err)
		}
		sw, err = switchOp.Read(ctx, zone, sw.ID)
		if err != nil {
			return out, fmt.Errorf("read switch: %w", err)
		}
	}
	if out.InternalSwitchID == "" {
		out.InternalSwitchID = sw.ID.String()
	}
	if len(out.InternalIPPool) == 0 && len(sw.Subnets) > 0 {
		s := sw.Subnets[0]
		out.InternalNetmask = s.NetworkMaskLen
		out.InternalIPPool = usableIPv4s(s.NetworkAddress, s.NetworkMaskLen, 0)
	}

	filterOp := iaas.NewPacketFilterOp(c.client)
	fr, err := filterOp.Find(ctx, zone, nil)
	if err != nil {
		return out, err
	}
	for _, v := range fr.PacketFilters {
		if v.Name == b.PacketFilterName {
			out.PacketFilterID = v.ID.String()
			break
		}
	}
	if out.PacketFilterID == "" {
		f, err := filterOp.Create(ctx, zone, &iaas.PacketFilterCreateRequest{Name: b.PacketFilterName, Description: "Omni Talos management", Expression: []*iaas.PacketFilterExpression{{Protocol: types.Protocols.ICMP, Action: types.Actions.Allow}, {Protocol: types.Protocols.TCP, DestinationPort: types.PacketFilterPort("50000"), Action: types.Actions.Allow}, {Protocol: types.Protocols.IP, Action: types.Actions.Deny}}})
		if err != nil {
			return out, fmt.Errorf("create packet filter: %w", err)
		}
		out.PacketFilterID = f.ID.String()
	}
	if out.ArchiveID == "" && b.SourceArchiveID != "" {
		source, err := parseID(b.SourceArchiveID)
		if err != nil {
			return out, fmt.Errorf("source_archive_id: %w", err)
		}
		name := b.ArchiveName
		if name == "" {
			name = "sakura-omni-talos"
		}
		a, err := iaas.NewArchiveOp(c.client).Create(ctx, zone, &iaas.ArchiveCreateRequest{Name: name, SourceArchiveID: source, Tags: types.Tags{"omni-managed=sakura", "omni-talos-image=true"}})
		if err != nil {
			return out, fmt.Errorf("create Talos archive: %w", err)
		}
		out.ArchiveID = a.ID.String()
	}
	return out, nil
}

func usableIPv4s(network string, mask, limit int) []string {
	ip, n, err := net.ParseCIDR(fmt.Sprintf("%s/%d", network, mask))
	if err != nil {
		return nil
	}
	ip = ip.Mask(n.Mask)
	var out []string
	for x := ip.Mask(n.Mask); n.Contains(x); incIPv4(x) {
		if x.Equal(ip) {
			continue
		}
		last := append(net.IP(nil), x...)
		incIPv4(last)
		if !n.Contains(last) {
			break
		}
		if x.Equal(last) {
			break
		}
		out = append(out, x.String())
		if limit > 0 && len(out) >= limit {
			break
		}
	}
	if len(out) > 1 {
		out = out[:len(out)-1]
	}
	return out
}
func incIPv4(ip net.IP) {
	for i := len(ip) - 1; i >= 0; i-- {
		ip[i]++
		if ip[i] != 0 {
			break
		}
	}
}

func parseID(value string) (types.ID, error) {
	id, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid Sakura Cloud ID %q: %w", value, err)
	}
	return types.ID(id), nil
}

func (c *SakuraCloud) UsedIPs(ctx context.Context, zone string) ([]string, error) {
	result, err := iaas.NewServerOp(c.client).Find(ctx, zone, nil)
	if err != nil {
		return nil, err
	}
	var ips []string
	for _, server := range result.Servers {
		for _, nic := range server.Interfaces {
			if nic.UserIPAddress != "" {
				ips = append(ips, nic.UserIPAddress)
			}
		}
	}
	return ips, nil
}

func (c *SakuraCloud) CreateCDROM(ctx context.Context, zone, name, isoPath string) (string, error) {
	cdrom, err := cdromsvc.New(c.client).CreateWithContext(ctx, &cdromsvc.CreateRequest{
		Zone: zone, Name: name + "-cidata", SizeGB: 5, SourcePath: isoPath,
		Tags: types.Tags{"omni-infra-provider=sakura", "omni-machine=" + name},
	})
	if err != nil {
		return "", err
	}
	return cdrom.ID.String(), nil
}

func (c *SakuraCloud) CreateMachine(ctx context.Context, req CreateMachineRequest) (MachineResources, error) {
	archiveID, err := parseID(req.Class.ArchiveID)
	if err != nil {
		return MachineResources{}, err
	}
	externalSwitchID, err := parseID(req.Class.ExternalSwitchID)
	if err != nil {
		return MachineResources{}, err
	}
	internalSwitchID, err := parseID(req.Class.InternalSwitchID)
	if err != nil {
		return MachineResources{}, err
	}
	cdromID, err := parseID(req.CDROMID)
	if err != nil {
		return MachineResources{}, err
	}
	packetFilterID := types.ID(0)
	if req.Class.PacketFilterID != "" {
		packetFilterID, err = parseID(req.Class.PacketFilterID)
		if err != nil {
			return MachineResources{}, err
		}
	}

	tags := types.Tags{"omni-infra-provider=sakura", "omni-machine=" + req.Name}
	diskClient := diskbuilder.NewBuildersAPIClient(c.client)
	disks := []diskbuilder.Builder{&diskbuilder.FromDiskOrArchiveBuilder{
		SourceArchiveID: archiveID, Name: req.Name, SizeGB: req.Class.DiskGiB,
		PlanID: types.DiskPlans.SSD, Connection: types.DiskConnections.VirtIO,
		Tags: tags, Client: diskClient,
	}}
	if req.Class.DataDiskGiB > 0 {
		disks = append(disks, &diskbuilder.BlankBuilder{
			Name: req.Name + "-data", SizeGB: req.Class.DataDiskGiB,
			PlanID: types.DiskPlans.SSD, Connection: types.DiskConnections.VirtIO,
			Tags: tags, Client: diskClient,
		})
	}

	builder := &serverbuilder.Builder{
		Name: req.Name, CPU: req.Class.CPU, MemoryGB: req.Class.MemoryGiB,
		InterfaceDriver: types.InterfaceDrivers.VirtIO, Tags: tags, CDROMID: cdromID,
		NIC: &serverbuilder.ConnectedNICSetting{
			SwitchID: externalSwitchID, DisplayIPAddress: req.ExternalIP, PacketFilterID: packetFilterID,
		},
		AdditionalNICs: []serverbuilder.AdditionalNICSettingHolder{&serverbuilder.ConnectedNICSetting{
			SwitchID: internalSwitchID, DisplayIPAddress: req.InternalIP,
		}},
		DiskBuilders: disks, Client: serverbuilder.NewBuildersAPIClient(c.client), BootAfterCreate: true,
	}
	if err := builder.Validate(ctx, req.Class.Zone); err != nil {
		return MachineResources{}, err
	}
	result, err := builder.Build(ctx, req.Class.Zone)
	if err != nil {
		return MachineResources{}, err
	}
	resources := MachineResources{ServerID: result.ServerID.String(), DiskIDs: make([]string, 0, len(result.DiskIDs))}
	for _, id := range result.DiskIDs {
		resources.DiskIDs = append(resources.DiskIDs, id.String())
	}
	return resources, nil
}

func (c *SakuraCloud) DeleteMachine(ctx context.Context, zone, serverID string, diskIDs []string, cdromID string) error {
	serverOp := iaas.NewServerOp(c.client)
	if serverID != "" {
		id, err := parseID(serverID)
		if err != nil {
			return err
		}
		server, err := serverOp.Read(ctx, zone, id)
		switch {
		case err == nil:
			if server.InstanceStatus.IsUp() {
				if err := power.ShutdownServer(ctx, serverOp, zone, id, true); err != nil {
					return err
				}
			}
			if err := serverOp.Delete(ctx, zone, id); err != nil {
				return err
			}
		case !iaas.IsNotFoundError(err):
			return err
		}
	}
	for _, value := range diskIDs {
		id, err := parseID(value)
		if err != nil {
			return err
		}
		if err := iaas.NewDiskOp(c.client).Delete(ctx, zone, id); err != nil && !iaas.IsNotFoundError(err) {
			return err
		}
	}
	if cdromID != "" {
		id, err := parseID(cdromID)
		if err != nil {
			return err
		}
		if err := cleanup.DeleteCDROM(ctx, c.client, zone, id, query.CheckReferencedOption{}); err != nil && !iaas.IsNotFoundError(err) {
			return err
		}
	}
	return nil
}

func (c *SakuraCloud) Health(ctx context.Context, zone string) error {
	_, err := iaas.NewServerOp(c.client).Find(ctx, zone, &iaas.FindCondition{Count: 1})
	return err
}
