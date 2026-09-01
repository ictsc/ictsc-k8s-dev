package provider

import (
	"github.com/cosi-project/runtime/pkg/resource/meta"
	"github.com/cosi-project/runtime/pkg/resource/protobuf"
	"github.com/cosi-project/runtime/pkg/resource/typed"
	"github.com/ictsc/ictsc-k8s-dev/omni/infra-provider-sakura/api/spec"
	"github.com/siderolabs/omni/client/pkg/infra"
)

type Machine = typed.Resource[MachineSpec, MachineExtension]
type MachineSpec = protobuf.ResourceSpec[spec.MachineSpec, *spec.MachineSpec]
type MachineExtension struct{}

func (MachineExtension) ResourceDefinition() meta.ResourceDefinitionSpec {
	return meta.ResourceDefinitionSpec{
		Type:             infra.ResourceType("Machine", ID),
		DefaultNamespace: infra.ResourceNamespace(ID),
	}
}
