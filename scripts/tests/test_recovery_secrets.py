import importlib.util
from pathlib import Path
import unittest
from unittest.mock import Mock

spec = importlib.util.spec_from_file_location('recovery', Path(__file__).resolve().parents[1] / 'recovery-secrets.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class VaultSafety(unittest.TestCase):
    def vault(self):
        vault = module.Vault.__new__(module.Vault)
        vault.names = {'existing'}
        vault.get = Mock(return_value='original')
        vault.api = Mock()
        return vault

    def test_existing_different_secret_is_not_overwritten(self):
        vault = self.vault()
        with self.assertRaisesRegex(RuntimeError, 'not overwritten'):
            vault.put('existing', 'changed')
        vault.api.assert_not_called()

    def test_new_secret_requires_matching_readback(self):
        vault = self.vault()
        with self.assertRaisesRegex(RuntimeError, 'read-back mismatch'):
            vault.put('new', 'expected')
        vault.api.assert_called_once()

    def test_size_limit_checked_in_bytes_before_api(self):
        vault = self.vault()
        with self.assertRaises(ValueError):
            vault.put('new', '\u3042' * 22000)
        vault.api.assert_not_called()
