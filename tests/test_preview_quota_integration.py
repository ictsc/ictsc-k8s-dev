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
        # Minimal namespaced Argo CRDs exercise Kubernetes' native object
        # count admission without deploying the Argo CD controllers.
        for plural, singular, kind in (("applications", "application", "Application"),
                                       ("applicationsets", "applicationset", "ApplicationSet")):
            crd = {
                "apiVersion": "apiextensions.k8s.io/v1", "kind": "CustomResourceDefinition",
                "metadata": {"name": f"{plural}.argoproj.io"},
                "spec": {"group": "argoproj.io", "scope": "Namespaced",
                         "names": {"plural": plural, "singular": singular, "kind": kind},
                         "versions": [{"name": "v1alpha1", "served": True, "storage": True,
                                       "schema": {"openAPIV3Schema": {"type": "object",
                                       "x-kubernetes-preserve-unknown-fields": True}}}]}}
            kubectl("apply", "-f", "-", input=yaml.safe_dump(crd))
            kubectl("wait", "--for=condition=Established", f"crd/{plural}.argoproj.io", "--timeout=60s")
        # kind starts kube-controller-manager before these test CRDs exist.
        # Restart the actual static-Pod container so its quota monitor
        # discovers both resources. Deleting only its mirror Pod does not
        # restart the container. The real Argo CRDs predate activation.
        container = subprocess.run(
            ["docker", "exec", "kind-control-plane", "crictl", "ps", "-q",
             "--name", "kube-controller-manager"],
            text=True, capture_output=True, check=True).stdout.strip()
        if not container or "\n" in container:
            raise AssertionError(f"expected one controller container, got: {container!r}")
        stopped = subprocess.run(["docker", "exec", "kind-control-plane", "crictl",
                                  "stop", container], text=True, capture_output=True)
        if stopped.returncode:
            raise AssertionError(f"could not restart disposable quota controller: "
                                 f"{stopped.stdout} {stopped.stderr}")
        docs = list(yaml.safe_load_all(PROPOSAL.read_text()))
        namespace, quota, project, appset = docs
        assert namespace["metadata"]["name"] == NAMESPACE
        assert quota["metadata"]["namespace"] == NAMESPACE
        assert appset["metadata"]["namespace"] == NAMESPACE
        assert appset["spec"]["template"]["metadata"]["namespace"] == NAMESPACE
        assert NAMESPACE in project["spec"]["sourceNamespaces"]
        assert quota["spec"]["hard"]["count/applications.argoproj.io"] == "3"
        kubectl("apply", "-f", "-", input=yaml.safe_dump_all([namespace, quota]))
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            result = kubectl("get", "quota", "preview-applications", "-n", NAMESPACE, "-o", "json")
            status = json.loads(result.stdout).get("status", {})
            if (status.get("hard", {}).get("count/applications.argoproj.io") == "3"
                    and status.get("used", {}).get("count/applications.argoproj.io") == "0"
                    and status.get("used", {}).get("count/applicationsets.argoproj.io") == "0"):
                break
            time.sleep(1)
        else:
            logs = kubectl("logs", "-n", "kube-system", "-l",
                           "component=kube-controller-manager", "--tail=80", check=False)
            raise AssertionError(f"ResourceQuota status did not become ready: {status}; "
                                 f"controller logs: {logs.stdout[-5000:]} {logs.stderr[-500:]}")

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
