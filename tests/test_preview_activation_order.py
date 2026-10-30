"""Keep GitOps prerequisites ahead of the health-gated ApplicationSet."""

import shutil
import subprocess
import unittest
from pathlib import Path

import yaml

yaml.SafeLoader.add_constructor('tag:yaml.org,2002:value',
                                lambda loader, node: loader.construct_scalar(node))

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("kubectl"), "kubectl unavailable")
class PreviewActivationOrderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        rendered = subprocess.check_output(
            ["kubectl", "kustomize", str(ROOT / "manifest/envs/dev")], text=True)
        cls.docs = [d for d in yaml.safe_load_all(rendered) if d]

    def resource(self, kind, name, namespace=None):
        matches = [d for d in self.docs if d["kind"] == kind
                   and d["metadata"]["name"] == name
                   and d["metadata"].get("namespace") == namespace]
        self.assertEqual(len(matches), 1, (kind, name, namespace))
        return matches[0]

    def wave(self, kind, name, namespace=None):
        obj = self.resource(kind, name, namespace)
        return int(obj["metadata"]["annotations"]["argocd.argoproj.io/sync-wave"])

    def test_secret_and_controller_are_healthy_before_appset(self):
        control = "regalia-preview-control"
        namespace = self.wave("Namespace", control)
        quota = self.wave("ResourceQuota", "preview-applications", control)
        service_account = self.wave("ServiceAccount", "regalia-preview-appset-controller", control)
        role = self.wave("Role", "regalia-preview-appset-controller", control)
        binding = self.wave("RoleBinding", "regalia-preview-appset-controller", control)
        secret = self.wave("ExternalSecret", "regalia-pr-preview-github-app", control)
        store = self.wave("ClusterSecretStore", "regalia-preview-github-app-only")
        project = self.wave("AppProject", "regalia-pr-preview", control)
        deployment = self.wave("Deployment", "regalia-preview-appset-controller", control)
        cleanup = self.wave("CronJob", "regalia-preview-cleanup", "argocd")
        appset = self.wave("ApplicationSet", "regalia-pr-preview", control)
        self.assertLess(namespace, quota)
        self.assertLessEqual(quota, store)
        self.assertLess(store, min(service_account, role, binding, secret))
        self.assertLess(max(service_account, role, binding, secret), project)
        self.assertLess(project, deployment)
        self.assertLess(deployment, cleanup)
        self.assertLess(cleanup, appset)
        # Quota-full AppSet is legitimately Degraded. It must not hold back
        # future syncs of unrelated root resources (including Argo itself).
        other_waves = [int(d["metadata"].get("annotations", {}).get(
            "argocd.argoproj.io/sync-wave", "0")) for d in self.docs
            if d["kind"] != "ApplicationSet" or d["metadata"]["name"] != "regalia-pr-preview"]
        self.assertGreater(appset, max(other_waves))

    def test_controller_watches_only_its_namespace(self):
        deployment = self.resource("Deployment", "regalia-preview-appset-controller",
                                   "regalia-preview-control")
        self.assertEqual(deployment["spec"]["replicas"], 1)
        args = deployment["spec"]["template"]["spec"]["containers"][0]["args"]
        self.assertFalse(any("applicationset-namespaces" in arg for arg in args))
        self.assertIn("--enable-leader-election=false", args)


if __name__ == "__main__":
    unittest.main()
