"""Exercise atomic quota admission in a disposable kind cluster."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import subprocess
import time
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
PROPOSAL = ROOT / "manifest/envs/dev/resources/regalia-pr-preview.yaml"
NAMESPACE = "regalia-preview-control"


def kubectl(*args, input=None, check=True):
    return subprocess.run(["kubectl", *args], input=input, text=True,
                          capture_output=True, check=check)


@unittest.skipUnless(os.getenv("PREVIEW_QUOTA_TEST") == "1", "requires disposable kind cluster")
class QuotaIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        namespace, quota, project, appset = list(yaml.safe_load_all(PROPOSAL.read_text()))
        assert namespace["metadata"]["name"] == NAMESPACE
        assert quota["metadata"]["namespace"] == NAMESPACE
        assert quota["spec"]["hard"]["count/applications.argoproj.io"] == "3"
        assert quota["spec"]["hard"]["count/applicationsets.argoproj.io"] == "1"
        assert appset["metadata"]["namespace"] == NAMESPACE
        assert appset["spec"]["template"]["metadata"]["namespace"] == NAMESPACE
        assert NAMESPACE in project["spec"]["sourceNamespaces"]
        # A newly installed fake Argo CRD has no usage monitor in the fresh
        # kind controller during this short test. Use a built-in namespaced
        # resource to test atomic admission, while retaining the exact CRD
        # quota as an activation gate on the actual Argo installation.
        quota["spec"]["hard"] = {"count/leases.coordination.k8s.io": "3"}
        kubectl("apply", "-f", "-", input=yaml.safe_dump_all([namespace, quota]))
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            result = kubectl("get", "quota", "preview-applications", "-n", NAMESPACE,
                             "-o", "json")
            status = json.loads(result.stdout).get("status", {})
            if (status.get("hard", {}).get("count/leases.coordination.k8s.io") == "3"
                    and status.get("used", {}).get("count/leases.coordination.k8s.io") == "0"):
                break
            time.sleep(1)
        else:
            raise AssertionError(f"quota use did not initialize: {status}")

    def create(self, number):
        lease = {"apiVersion": "coordination.k8s.io/v1", "kind": "Lease",
                 "metadata": {"name": f"regalia-pr-{number}", "namespace": NAMESPACE},
                 "spec": {"holderIdentity": "quota-test"}}
        return kubectl("create", "-f", "-", input=yaml.safe_dump(lease), check=False)

    def names(self):
        result = kubectl("get", "leases.coordination.k8s.io", "-n", NAMESPACE, "-o", "json")
        return {item["metadata"]["name"] for item in json.loads(result.stdout)["items"]}

    def test_concurrent_create_never_exceeds_three_and_preserves_incumbents(self):
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(self.create, range(1, 9)))
        accepted = self.names()
        self.assertEqual(len(accepted), 3, [r.stderr for r in results])
        self.assertEqual(sum(r.returncode == 0 for r in results), 3)
        self.assertNotEqual(self.create(9).returncode, 0)
        self.assertEqual(self.names(), accepted)
        old = sorted(accepted)[0]
        kubectl("delete", "lease", old, "-n", NAMESPACE)
        self.assertEqual(self.create(9).returncode, 0)
        self.assertEqual(self.names(), (accepted - {old}) | {"regalia-pr-9"})


if __name__ == "__main__":
    unittest.main()
