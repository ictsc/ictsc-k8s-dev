package provider

import (
	"encoding/json"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestEmbeddedSchemaIsJSON(t *testing.T) {
	if !json.Valid([]byte(MachineClassSchema)) {
		t.Fatal("embedded machine class schema is not valid JSON")
	}
}

func validMachineClass() MachineClass {
	return MachineClass{
		Zone: "tk1b", ArchiveID: "123456789012", CPU: 2, MemoryGiB: 4, DiskGiB: 40,
		ExternalSwitchID: "123456789013", ExternalIPPool: []string{"203.0.113.10", "203.0.113.11"},
		ExternalGateway: "203.0.113.1", ExternalNetmask: 27, PacketFilterID: "123456789014",
		InternalSwitchID: "123456789015", InternalIPPool: []string{"192.168.100.10", "192.168.100.11"},
		InternalNetmask: 24, Nameservers: []string{"210.188.224.10"},
	}
}

func TestMachineClassValidate(t *testing.T) {
	mc := validMachineClass()
	if err := mc.Validate(); err != nil {
		t.Fatalf("valid machine class rejected: %v", err)
	}
	mc.InternalIPPool = mc.InternalIPPool[:1]
	if err := mc.Validate(); err == nil || !strings.Contains(err.Error(), "same length") {
		t.Fatalf("expected pool length error, got %v", err)
	}
}

func TestAllocatePair(t *testing.T) {
	mc := validMachineClass()
	external, internal, err := allocatePair(mc, usedIPSet([]string{"203.0.113.10"}))
	if err != nil {
		t.Fatal(err)
	}
	if external != "203.0.113.11" || internal != "192.168.100.11" {
		t.Fatalf("unexpected pair %s %s", external, internal)
	}
	_, _, err = allocatePair(mc, usedIPSet([]string{"203.0.113.10", "192.168.100.11"}))
	if err == nil {
		t.Fatal("expected exhausted pool error")
	}
}

func TestRenderNetworkPatch(t *testing.T) {
	data, err := renderNetworkPatch("omni-test", validMachineClass(), "203.0.113.10", "192.168.100.10")
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if err := yaml.Unmarshal(data, &value); err != nil {
		t.Fatal(err)
	}
	text := string(data)
	for _, expected := range []string{"hostname: omni-test", "203.0.113.10/27", "192.168.100.10/24", "gateway: 203.0.113.1"} {
		if !strings.Contains(text, expected) {
			t.Errorf("patch is missing %q:\n%s", expected, text)
		}
	}
}

func TestRenderUserData(t *testing.T) {
	got := string(renderUserData("machine:\n  type: worker\n", []byte("machine:\n  network: {}\n")))
	if !strings.Contains(got, "\n---\nmachine:\n  network") {
		t.Fatalf("documents were not separated: %q", got)
	}
}

func TestMachineNameIsStableAndBounded(t *testing.T) {
	request := strings.Repeat("Control_Plane.", 10)
	a, b := machineName(request), machineName(request)
	if a != b {
		t.Fatalf("name is not stable: %q != %q", a, b)
	}
	if len(a) > 53 {
		t.Fatalf("name is too long: %d %q", len(a), a)
	}
}
