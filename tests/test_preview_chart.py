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

    def test_missing_images_fail_before_database_without_running_pr_code(self):
        docs = self.render(True)
        jobs = {d["metadata"]["name"]: d for d in docs if d["kind"] == "Job"}
        check, migrate = jobs["preview-images"], jobs["preview-migrate"]
        wave = lambda d: int(d["metadata"].get("annotations", {}).get(
            "argocd.argoproj.io/sync-wave", "0"))
        others = [wave(d) for d in docs if d["metadata"]["name"] != "preview-images"]
        self.assertLess(wave(check), min(others))
        self.assertEqual(check["metadata"]["annotations"]["argocd.argoproj.io/hook"], "Sync")
        # ImagePullBackOff never counts toward backoffLimit; only the
        # deadline ends a Job whose image was never published.
        self.assertLessEqual(check["spec"]["activeDeadlineSeconds"], 180)
        self.assertGreaterEqual(migrate["spec"]["activeDeadlineSeconds"], 600)
        pod = check["spec"]["template"]["spec"]
        self.assertFalse(pod["automountServiceAccountToken"])
        self.assertEqual([c["image"] for c in pod["containers"]], ["postgres:16-alpine"])
        self.assertNotIn("initContainers", pod)
        refs = sorted(v["image"]["reference"] for v in pod["volumes"])
        self.assertEqual(refs, sorted(
            f"ghcr.io/ictsc/ictsc-regalia/{name}:pr-7-{'a' * 40}"
            for name in ("backend", "frontend", "migrations")))
        workload_images = {c["image"] for d in docs if d["kind"] in ("Deployment", "Job")
                           for c in d["spec"]["template"]["spec"].get("initContainers", [])
                           + d["spec"]["template"]["spec"]["containers"]
                           if "ictsc-regalia" in c["image"]}
        self.assertEqual(workload_images, set(refs))

    def test_missing_sha_fails(self):
        result = subprocess.run(["helm", "template", "preview", str(CHART), "--set", "prNumber=7"], capture_output=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
