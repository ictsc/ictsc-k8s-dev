import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('validation', Path(__file__).parents[1] / 'validate-gitops.py')
validation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validation)


class SchemaTests(unittest.TestCase):
    def test_nullable_required_field_is_preserved(self):
        schema = {'properties': {'keep': {'nullable': True}, 'prune': {'type': 'object'}}}
        self.assertEqual(validation.prune_null_fields({'keep': None, 'prune': None}, schema), {'keep': None})

    def test_array_schema_is_used_for_pruning(self):
        schema = {'items': {'properties': {'keep': {'nullable': True}}}}
        self.assertEqual(validation.prune_null_fields([{'keep': None, 'prune': None}], schema), [{'keep': None}])

    def test_int_or_string_schema_accepts_both_types(self):
        schema = validation.normalize({'x-kubernetes-int-or-string': True})
        self.assertEqual(schema['anyOf'], [{'type': 'integer'}, {'type': 'string'}])

    def test_alertmanager_match_operator_is_a_string(self):
        self.assertEqual(validation.documents('matchType: =')[0]['matchType'], '=')


if __name__ == '__main__':
    unittest.main()
