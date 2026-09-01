package provider

import (
	"context"
	"errors"
	"fmt"
	"hash/fnv"
	"strings"
	"sync"

	"github.com/siderolabs/omni/client/pkg/infra/provision"
	omniinfra "github.com/siderolabs/omni/client/pkg/omni/resources/infra"
	"go.uber.org/zap"
	"gopkg.in/yaml.v3"
)

var _ provision.Provisioner[*Machine] = (*Provisioner)(nil)

type Provisioner struct {
	cloud    Cloud
	mu       sync.Mutex
	defaults MachineClass
}

func NewProvisioner(cloud Cloud, defaults ...MachineClass) *Provisioner {
	p := &Provisioner{cloud: cloud}
	if len(defaults) > 0 {
		p.defaults = defaults[0]
	}
	return p
}

func (p *Provisioner) ProvisionSteps() []provision.Step[*Machine] {
	return []provision.Step[*Machine]{
		provision.NewStep("validate_request", p.validateRequest),
		provision.NewStep("ensure_machine", p.ensureMachine),
		provision.NewStep("ensure_provider_id", p.ensureProviderID),
	}
}

func (p *Provisioner) classFromContext(pctx provision.Context[*Machine]) (MachineClass, error) {
	var configured MachineClass
	if err := pctx.UnmarshalProviderData(&configured); err != nil {
		return configured, err
	}
	return mergeMachineClass(p.defaults, configured), nil
}

func (p *Provisioner) validateRequest(_ context.Context, _ *zap.Logger, pctx provision.Context[*Machine]) error {
	mc, err := p.classFromContext(pctx)
	if err == nil {
		err = mc.Validate()
	}
	return err
}

func machineName(requestID string) string {
	clean := strings.ToLower(requestID)
	var b strings.Builder
	for _, r := range clean {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-' {
			b.WriteRune(r)
		} else {
			b.WriteByte('-')
		}
	}
	clean = strings.Trim(b.String(), "-")
	if clean == "" {
		clean = "machine"
	}
	if len(clean) <= 48 {
		return "omni-" + clean
	}
	h := fnv.New32a()
	_, _ = h.Write([]byte(requestID))
	return fmt.Sprintf("omni-%s-%08x", clean[:39], h.Sum32())
}

func (p *Provisioner) ensureMachine(ctx context.Context, logger *zap.Logger, pctx provision.Context[*Machine]) error {
	state := pctx.State.TypedSpec().Value
	if state.ServerId != "" {
		return nil
	}
	mc, err := p.classFromContext(pctx)
	if err == nil {
		err = mc.Validate()
	}
	if err != nil {
		return err
	}

	// IP allocation and Sakura resource creation stay in one critical section. This
	// prevents concurrent requests from seeing the same still-unpublished address.
	p.mu.Lock()
	defer p.mu.Unlock()

	used, err := p.cloud.UsedIPs(ctx, mc.Zone)
	if err != nil {
		return fmt.Errorf("list used IP addresses: %w", err)
	}
	externalIP, internalIP, err := allocatePair(mc, usedIPSet(used))
	if err != nil {
		return err
	}
	name := machineName(pctx.GetRequestID())
	networkPatch, err := renderNetworkPatch(name, mc, externalIP, internalIP)
	if err != nil {
		return err
	}
	if err := pctx.CreateConfigPatch(ctx, "sakura-network-"+name, networkPatch); err != nil {
		return fmt.Errorf("create network config patch: %w", err)
	}
	isoPath, cleanupISO, err := buildCIDATA(ctx, name, renderUserData(pctx.ConnectionParams.JoinConfig, networkPatch))
	if err != nil {
		return err
	}
	defer cleanupISO()
	cdromID, err := p.cloud.CreateCDROM(ctx, mc.Zone, name, isoPath)
	if err != nil {
		return fmt.Errorf("create cidata CD-ROM: %w", err)
	}
	state.Zone, state.CdromId = mc.Zone, cdromID
	state.ExternalIp, state.InternalIp = externalIP, internalIP

	resources, err := p.cloud.CreateMachine(ctx, CreateMachineRequest{
		Name: name, Class: mc, ExternalIP: externalIP, InternalIP: internalIP, CDROMID: cdromID,
	})
	if err != nil {
		cleanupErr := p.cloud.DeleteMachine(context.WithoutCancel(ctx), mc.Zone, "", nil, cdromID)
		if cleanupErr != nil {
			return errors.Join(fmt.Errorf("create Sakura Cloud machine: %w", err), fmt.Errorf("clean up cidata CD-ROM: %w", cleanupErr))
		}
		return fmt.Errorf("create Sakura Cloud machine: %w", err)
	}
	state.ServerId, state.DiskIds = resources.ServerID, resources.DiskIDs
	logger.Info("created Sakura Cloud machine", zap.String("server_id", state.ServerId), zap.String("external_ip", externalIP), zap.String("internal_ip", internalIP))
	return nil
}

func (p *Provisioner) ensureProviderID(ctx context.Context, _ *zap.Logger, pctx provision.Context[*Machine]) error {
	serverID := pctx.State.TypedSpec().Value.ServerId
	if serverID == "" {
		return errors.New("server ID is empty")
	}
	patch := map[string]any{"machine": map[string]any{"kubelet": map[string]any{"extraConfig": map[string]string{
		"providerID": "sakura://" + serverID,
	}}}}
	data, err := yaml.Marshal(patch)
	if err != nil {
		return err
	}
	return pctx.CreateConfigPatch(ctx, "sakura-provider-id-"+machineName(pctx.GetRequestID()), data)
}

func (p *Provisioner) Deprovision(ctx context.Context, _ *zap.Logger, machine *Machine, _ *omniinfra.MachineRequest) error {
	state := machine.TypedSpec().Value
	if state == nil {
		return nil
	}
	return p.cloud.DeleteMachine(ctx, state.Zone, state.ServerId, state.DiskIds, state.CdromId)
}
