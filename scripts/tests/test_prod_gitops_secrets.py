import base64
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('bootstrap', Path(__file__).parents[1] / 'prod-gitops-secrets.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.data = {key: {field: base64.b64encode(b'fictional-test-value').decode() for field in fields}
                     for key, fields in module.REQUIRED.items()}
        self.existing = dict(self.data)

    def read(self, *args):
        if args == ('get', 'nodes'):
            return {'items': [{'metadata': {'name': 'ictsc-prod-worker-1'}}]}
        if args[0] == 'get':
            return {'metadata': {'name': args[2]}}
        key = args[1] + '/' + args[4]
        return {'data': self.existing[key]} if key in self.existing else None

    def bundle(self, directory):
        path = Path(directory) / 'bundle.json'
        path.write_text(json.dumps({'version': 1, 'environment': 'prod', 'secrets': self.data}))
        path.chmod(0o600)
        return path

    def test_existing_prod_does_not_read_bundle_or_write(self):
        with patch.object(module, 'read', side_effect=self.read), patch.object(module, 'create') as create:
            module.reconcile('/nonexistent/dev-unavailable')
            create.assert_not_called()

    def test_api_failure_is_not_missing(self):
        with patch.object(module, 'read', side_effect=RuntimeError('API down')), patch.object(module, 'create') as create:
            with self.assertRaises(RuntimeError):
                module.reconcile()
            create.assert_not_called()

    def test_missing_only_is_restored(self):
        del self.existing['argocd/argocd-oidc']
        with tempfile.TemporaryDirectory() as directory, patch.object(module, 'read', side_effect=self.read), patch.object(module, 'create') as create:
            module.reconcile(self.bundle(directory))
            self.assertEqual(create.call_count, 1)
            self.assertEqual(create.call_args.args[0]['metadata']['name'], 'argocd-oidc')

    def test_stale_bundle_rejected_before_any_write(self):
        del self.existing['argocd/argocd-oidc']
        self.data['argocd/argocd-oidc'] = {'clientSecret': base64.b64encode(b'stale').decode()}
        with tempfile.TemporaryDirectory() as directory, patch.object(module, 'read', side_effect=self.read), patch.object(module, 'create') as create:
            with self.assertRaisesRegex(ValueError, 'disagree'):
                module.reconcile(self.bundle(directory))
            create.assert_not_called()

    def test_wrong_environment_and_public_bundle_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.bundle(directory)
            path.chmod(0o644)
            with self.assertRaises(ValueError):
                module.load_bundle(path)
            path.chmod(0o600)
            bundle = json.loads(path.read_text())
            bundle['environment'] = 'dev'
            path.write_text(json.dumps(bundle))
            with self.assertRaises(ValueError):
                module.load_bundle(path)

    def test_export_never_overwrites(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(module, 'read', side_effect=self.read):
            path = self.bundle(directory)
            before = path.read_bytes()
            with self.assertRaises(FileExistsError):
                module.reconcile(export_path=path)
            self.assertEqual(path.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
