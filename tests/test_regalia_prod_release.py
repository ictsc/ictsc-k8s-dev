"""The prod release PR must only move images, and only to one dev commit."""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/regalia/sync-prod-images.py"
OVERLAYS = ROOT / "manifest/base/apps/regalia/workload/overlays"


def load_script():
    spec = importlib.util.spec_from_file_location("sync_prod_images", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ProdReleaseTests(unittest.TestCase):
    def run_sync(self, dev_tags):
        sync = load_script()
        with tempfile.TemporaryDirectory() as tmp:
            dev, prod = Path(tmp, "dev"), Path(tmp, "prod")
            shutil.copytree(OVERLAYS / "openapi-dev", dev)
            shutil.copytree(OVERLAYS / "openapi-prod", prod)
            data = yaml.safe_load((dev / "kustomization.yaml").read_text())
            for image in data["images"]:
                image["newTag"] = dev_tags[image["name"]]
            (dev / "kustomization.yaml").write_text(yaml.safe_dump(data, sort_keys=False))
            before = (prod / "kustomization.yaml").read_text()
            with mock.patch.object(sync, "DEV", dev), mock.patch.object(sync, "PROD", prod), \
                    mock.patch("sys.argv", ["sync", "--summary", str(Path(tmp, "body.md"))]):
                self.assertEqual(sync.main(), 0)
            return before, (prod / "kustomization.yaml").read_text()

    def test_moves_only_images_to_the_dev_commit(self):
        tag = "sha-" + "a" * 40
        before, after = self.run_sync({"backend": tag, "frontend": tag, "migrations": tag})
        old, new = yaml.safe_load(before), yaml.safe_load(after)
        images = {image["name"]: image for image in new.pop("images")}
        old.pop("images")
        self.assertEqual(old, new)
        for name in ("backend", "frontend", "migrations"):
            self.assertEqual(images[name]["newTag"], tag)
            self.assertNotIn("digest", images[name])

    def test_skips_partly_published_dev_build(self):
        a, b = "sha-" + "a" * 40, "sha-" + "b" * 40
        before, after = self.run_sync({"backend": a, "frontend": a, "migrations": b})
        self.assertEqual(before, after)


if __name__ == "__main__":
    unittest.main()
