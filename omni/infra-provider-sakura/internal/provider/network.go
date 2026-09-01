package provider

import (
	"errors"
	"fmt"
	"sort"

	"gopkg.in/yaml.v3"
)

func allocatePair(mc MachineClass, used map[string]struct{}) (string, string, error) {
	for i := range mc.ExternalIPPool {
		external, internal := mc.ExternalIPPool[i], mc.InternalIPPool[i]
		if _, ok := used[external]; ok {
			continue
		}
		if _, ok := used[internal]; ok {
			continue
		}
		return external, internal, nil
	}
	return "", "", errors.New("machine class IP pools are exhausted")
}

func renderNetworkPatch(hostname string, mc MachineClass, externalIP, internalIP string) ([]byte, error) {
	patch := map[string]any{"machine": map[string]any{"network": map[string]any{
		"hostname":    hostname,
		"nameservers": mc.Nameservers,
		"interfaces": []any{
			map[string]any{
				"interface": "eth0",
				"addresses": []string{fmt.Sprintf("%s/%d", externalIP, mc.ExternalNetmask)},
				"routes":    []any{map[string]any{"network": "0.0.0.0/0", "gateway": mc.ExternalGateway}},
			},
			map[string]any{
				"interface": "eth1",
				"addresses": []string{fmt.Sprintf("%s/%d", internalIP, mc.InternalNetmask)},
			},
		},
	}}}
	return yaml.Marshal(patch)
}

func renderUserData(joinConfig string, networkPatch []byte) []byte {
	result := append([]byte(joinConfig), '\n')
	result = append(result, []byte("---\n")...)
	return append(result, networkPatch...)
}

func usedIPSet(values []string) map[string]struct{} {
	result := make(map[string]struct{}, len(values))
	for _, value := range values {
		result[value] = struct{}{}
	}
	return result
}

func sortedKeys(values map[string]struct{}) []string {
	result := make([]string, 0, len(values))
	for value := range values {
		result = append(result, value)
	}
	sort.Strings(result)
	return result
}
