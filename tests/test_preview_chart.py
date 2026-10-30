import shutil
import subprocess
from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / "manifest/base/apps/regalia/pr-preview"


@unittest.skipUnless(shutil.which("helm"), "Helm unavailable locally")
class ChartTests(unittest.TestCase):
    def render(self, exposure):
        result = subprocess.check_output([
            "helm", "template", "preview", str(CHART), "--namespace", "regalia-pr-7",
            "--set", "prNumber=7", "--set", "headSHA=" + "a" * 40,
            "--set", "enableExposure=" + str(exposure).lower()], text=True)
        return [d for d in yaml.safe_load_all(result) if d]

    def test_default_has_no_route(self):
        docs = self.render(False)
        self.assertFalse(any(d["kind"] in ("HTTPRoute", "ListenerSet", "Certificate") for d in docs))
        self.assertEqual([d["metadata"]["name"] for d in docs if d["kind"] == "Namespace"], ["regalia-pr-7"])

    def test_exposure_routes_only_to_proxy(self):
        docs = self.render(True)
        routes = [d for d in docs if d["kind"] == "HTTPRoute"]
        self.assertEqual(len(routes), 2)
        self.assertEqual(routes[0]["spec"]["rules"][0]["backendRefs"][0]["name"], "preview-proxy")
        self.assertTrue(any(d["kind"] == "ListenerSet" for d in docs))

    def test_preview_containers_start_with_numeric_nonroot_users(self):
        docs = self.render(True)
        deployments = {d["metadata"]["name"]: d for d in docs if d["kind"] == "Deployment"}
        for name, uid in (("preview-valkey", 999), ("preview-proxy", 65532)):
            pod = deployments[name]["spec"]["template"]["spec"]
            security = pod["securityContext"]
            self.assertTrue(security["runAsNonRoot"])
            self.assertEqual(security["runAsUser"], uid)
            self.assertEqual(security["runAsGroup"], uid)
            self.assertEqual(security["seccompProfile"]["type"], "RuntimeDefault")
            container_security = pod["containers"][0]["securityContext"]
            self.assertFalse(container_security["allowPrivilegeEscalation"])
            self.assertEqual(container_security["capabilities"]["drop"], ["ALL"])

    def test_missing_sha_fails(self):
        result = subprocess.run(["helm", "template", "preview", str(CHART), "--set", "prNumber=7"], capture_output=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
