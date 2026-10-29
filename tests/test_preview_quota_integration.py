"""Run only against a disposable kind cluster (PREVIEW_QUOTA_TEST=1)."""
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
        # A minimal namespaced Application CRD exercises Kubernetes' native
        # count/applications.argoproj.io admission without deploying Argo CD.
        crd = {
            "apiVersion": "apiextensions.k8s.io/v1", "kind": "CustomResourceDefinition",
            "metadata": {"name": "applications.argoproj.io"},
            "spec": {"group": "argoproj.io", "scope": "Namespaced",
                     "names": {"plural": "applications", "singular": "application", "kind": "Application"},
                     "versions": [{"name": "v1alpha1", "served": True, "storage": True,
                                   "schema": {"openAPIV3Schema": {"type": "object",
                                   "x-kubernetes-preserve-unknown-fields": True}}}]}}
        kubectl("apply", "-f", "-", input=yaml.safe_dump(crd))
        kubectl("wait", "--for=condition=Established", "crd/applications.argoproj.io", "--timeout=60s")
        docs = list(yaml.safe_load_all(PROPOSAL.read_text()))
        namespace, quota, project, appset = docs
        assert namespace["metadata"]["name"] == NAMESPACE
        assert quota["metadata"]["namespace"] == NAMESPACE
        assert appset["metadata"]["namespace"] == NAMESPACE
        assert appset["spec"]["template"]["metadata"]["namespace"] == NAMESPACE
        assert NAMESPACE in project["spec"]["sourceNamespaces"]
        assert quota["spec"]["hard"]["count/applications.argoproj.io"] == "3"
        kubectl("apply", "-f", "-", input=yaml.safe_dump_all([namespace, quota]))
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            result = kubectl("get", "quota", "preview-applications", "-n", NAMESPACE, "-o", "json")
            status = json.loads(result.stdout).get("status", {})
            if status.get("hard", {}).get("count/applications.argoproj.io") == "3":
                break
            time.sleep(1)
        else:
            raise AssertionError("ResourceQuota status did not become ready")

    def create(self, number):
        app = {"apiVersion": "argoproj.io/v1alpha1", "kind": "Application",
               "metadata": {"name": f"regalia-pr-{number}", "namespace": NAMESPACE},
               "spec": {}}
        return kubectl("create", "-f", "-", input=yaml.safe_dump(app), check=False)

    def names(self):
        result = kubectl("get", "applications.argoproj.io", "-n", NAMESPACE, "-o", "json")
        return {item["metadata"]["name"] for item in json.loads(result.stdout)["items"]}

    def test_concurrent_create_never_exceeds_three_and_preserves_incumbents(self):
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(self.create, range(1, 9)))
        accepted = self.names()
        self.assertEqual(len(accepted), 3, [r.stderr for r in results])
        self.assertEqual(sum(r.returncode == 0 for r in results), 3)
        # Reconciliation of further PRs cannot replace an incumbent at quota.
        self.assertNotEqual(self.create(9).returncode, 0)
        self.assertEqual(self.names(), accepted)
        old = sorted(accepted)[0]
        kubectl("delete", "application", old, "-n", NAMESPACE)
        self.assertEqual(self.create(9).returncode, 0)
        self.assertEqual(self.names(), (accepted - {old}) | {"regalia-pr-9"})


if __name__ == "__main__":
    unittest.main()
