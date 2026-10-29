"""Guard against a migration Job reporting success when psql fails."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
MIGRATE = ROOT / "manifest/base/apps/regalia/pr-preview/templates/migrate.yaml"


class MigrationTests(unittest.TestCase):
    def test_psql_failure_after_pg_isready_fails_job(self):
        manifest = MIGRATE.read_text().replace("{{ .Values.prNumber }}", "7").replace(
            "{{ .Values.headSHA }}", "a" * 40)
        job = yaml.safe_load(manifest)
        script = job["spec"]["template"]["spec"]["containers"][0]["args"][0]
        with tempfile.TemporaryDirectory() as tmp:
            for name, body in {"pg_isready": "exit 0", "psql": "exit 2"}.items():
                path = Path(tmp) / name
                path.write_text("#!/bin/sh\n" + body + "\n")
                path.chmod(0o755)
            env = dict(os.environ, PATH=tmp + ":" + os.environ["PATH"])
            result = subprocess.run(["sh", "-ec", script], env=env, capture_output=True)
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
