import unittest
from urllib.error import HTTPError
from unittest.mock import patch, mock_open
import cleanup
from cleanup import eligible_numbers, obsolete_owned_apps, still_ineligible


def app(number, *, owner="owner-uid", name=None):
    return {"metadata": {"name": name or f"regalia-pr-{number}",
                         "namespace": "regalia-preview-control",
                         "uid": f"app-{number}", "resourceVersion": "12",
                         "ownerReferences": [{"apiVersion": "argoproj.io/v1alpha1",
                                              "kind": "ApplicationSet",
                                              "name": "regalia-pr-preview", "uid": owner}]}}


def pull(number, *, state="open", preview=True):
    return {"number": number, "state": state,
            "labels": [{"name": "preview"}] if preview else []}


class CleanupTests(unittest.TestCase):
    def test_eligible_list_uses_complete_paginated_snapshot(self):
        pages = [list(map(pull, range(1, 101))), [pull(101), pull(102, preview=False)]]
        calls = []
        def request(url, *, token):
            calls.append(url)
            return pages[len(calls) - 1]
        self.assertEqual(eligible_numbers("token", request), set(range(1, 102)))
        self.assertEqual(len(calls), 2)

    def test_bad_or_incomplete_listing_fails_without_deletion_candidates(self):
        with self.assertRaises(ValueError):
            eligible_numbers("token", lambda *args, **kw: {"message": "error"})
        with self.assertRaises(ValueError):
            eligible_numbers("token", lambda *args, **kw: [pull(1, state="unknown")])

    def test_only_obsolete_owned_preview_apps_selected(self):
        apps = [app(1), app(2), app(3), app(4), app(5, owner="other"),
                app(6, name="unrelated-6"),
                {**app(7), "metadata": {**app(7)["metadata"],
                                         "namespace": "argocd"}}]
        self.assertEqual([n for n, _ in obsolete_owned_apps(apps, "owner-uid", {1, 3, 4})],
                         [2])

    def test_recheck_prevents_deletion_after_relabel(self):
        self.assertFalse(still_ineligible(2, "token",
            lambda *args, **kw: pull(2)))
        self.assertTrue(still_ineligible(2, "token",
            lambda *args, **kw: pull(2, preview=False)))
        self.assertTrue(still_ineligible(2, "token",
            lambda *args, **kw: pull(2, state="closed")))
        with self.assertRaises(ValueError):
            still_ineligible(2, "token", lambda *args, **kw: pull(3))
        with self.assertRaises(ValueError):
            still_ineligible(2, "token", lambda *args, **kw:
                             {**pull(2), "labels": [None]})

    def test_run_deletes_only_stale_owned_app_with_preconditions(self):
        deletes = []
        def github(url, **kwargs):
            if "/pulls?" in url:
                return [pull(1), pull(3)]
            if url.endswith("/pulls/2"):
                return pull(2, preview=False)
            raise AssertionError(url)
        def kube(path, **kwargs):
            if path.endswith("/applicationsets/regalia-pr-preview"):
                return {"metadata": {"uid": "owner-uid"}}
            if "/applications?" in path:
                return {"items": [app(1), app(2), app(3), app(4, owner="other")],
                        "metadata": {}}
            if kwargs.get("method") == "DELETE":
                deletes.append((path, kwargs["body"]))
                return {"kind": "Status", "status": "Success"}
            raise AssertionError(path)
        with patch.object(cleanup, "github_token", return_value="gh-token"), \
                patch.dict(cleanup.os.environ, {"GITHUB_APP_ID": "1",
                                             "GITHUB_APP_INSTALLATION_ID": "2",
                                             "GITHUB_APP_PRIVATE_KEY": "test"}), \
                patch("builtins.open", mock_open(read_data="sa-token")):
            cleanup.run(kube, github)
        self.assertEqual(len(deletes), 1)
        self.assertTrue(deletes[0][0].endswith("/applications/regalia-pr-2"))
        self.assertEqual(deletes[0][1]["preconditions"],
                         {"uid": "app-2", "resourceVersion": "12"})

    def test_conflict_on_one_stale_app_does_not_block_next(self):
        deleted = []
        def github(url, **kwargs):
            if "/pulls?" in url:
                return []
            if url.endswith("/pulls/1") or url.endswith("/pulls/2"):
                return pull(int(url.rsplit("/", 1)[1]), state="closed")
            raise AssertionError(url)
        def kube(path, **kwargs):
            if path.endswith("/applicationsets/regalia-pr-preview"):
                return {"metadata": {"uid": "owner-uid"}}
            if "/applications?" in path:
                return {"items": [app(1), app(2)], "metadata": {}}
            if kwargs.get("method") == "DELETE":
                deleted.append(path)
                if path.endswith("regalia-pr-1"):
                    raise HTTPError(path, 409, "conflict", {}, None)
                return {"status": "Success"}
            raise AssertionError(path)
        with patch.object(cleanup, "github_token", return_value="gh-token"), \
                patch.dict(cleanup.os.environ, {"GITHUB_APP_ID": "1",
                                             "GITHUB_APP_INSTALLATION_ID": "2",
                                             "GITHUB_APP_PRIVATE_KEY": "test"}), \
                patch("builtins.open", mock_open(read_data="sa-token")):
            cleanup.run(kube, github)
        self.assertEqual(len(deleted), 2)


if __name__ == "__main__":
    unittest.main()
