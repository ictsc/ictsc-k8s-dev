"""Delete only obsolete Regalia preview Applications; fail closed on API errors."""

import json
import os
import re
import ssl
import time
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen

import jwt


GITHUB = "https://api.github.com"
KUBE = "https://kubernetes.default.svc"
REPO = "ictsc/ictsc-regalia"
NAMESPACE = "regalia-preview-control"
APPSET = "regalia-pr-preview"
APP_NAME = re.compile(r"^regalia-pr-([1-9][0-9]*)$")
PAGE_LIMIT = 100


def has_preview_label(labels):
    if not isinstance(labels, list) or any(
            not isinstance(label, dict) or not isinstance(label.get("name"), str)
            for label in labels):
        raise ValueError("malformed GitHub labels")
    return any(label["name"] == "preview" for label in labels)


def request_json(url, *, token, method="GET", body=None, ssl_context=None):
    data = None if body is None else json.dumps(body).encode()
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    with urlopen(Request(url, data=data, headers=headers, method=method),
                 timeout=15, context=ssl_context) as response:
        return json.load(response)


def github_token(app_id, installation_id, private_key, request=request_json):
    now = int(time.time())
    assertion = jwt.encode({"iat": now - 60, "exp": now + 540,
                            "iss": app_id}, private_key, algorithm="RS256")
    response = request(f"{GITHUB}/app/installations/{installation_id}/access_tokens",
                       token=assertion, method="POST", body={})
    token = response.get("token")
    if not isinstance(token, str) or not token:
        raise ValueError("GitHub App installation token missing")
    return token


def eligible_numbers(token, request=request_json):
    eligible = set()
    for page in range(1, PAGE_LIMIT + 1):
        items = request(f"{GITHUB}/repos/{REPO}/pulls?state=open&per_page=100&page={page}",
                        token=token)
        if not isinstance(items, list) or len(items) > 100:
            raise ValueError("incomplete GitHub pull request page")
        for item in items:
            number = item.get("number")
            labels = item.get("labels")
            if (not isinstance(number, int) or isinstance(number, bool) or number < 1
                    or item.get("state") != "open"):
                raise ValueError("malformed GitHub pull request")
            if has_preview_label(labels):
                eligible.add(number)
        if len(items) < 100:
            return eligible
    raise ValueError("GitHub pagination limit reached")


def still_ineligible(number, token, request=request_json):
    item = request(f"{GITHUB}/repos/{REPO}/pulls/{number}", token=token)
    if not isinstance(item, dict) or item.get("number") != number:
        raise ValueError("GitHub PR recheck did not match")
    labels = item.get("labels")
    if item.get("state") not in ("open", "closed"):
        raise ValueError("malformed GitHub PR recheck")
    return item["state"] == "closed" or not has_preview_label(labels)


def kubernetes_request(path, *, token, method="GET", body=None):
    context = ssl.create_default_context(
        cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
    return request_json(KUBE + path, token=token, method=method, body=body,
                        ssl_context=context)


def list_all(path, token, request=kubernetes_request):
    result = []
    continuation = ""
    for _ in range(PAGE_LIMIT):
        separator = "&" if "?" in path else "?"
        suffix = f"{separator}limit=200"
        if continuation:
            suffix += f"&continue={quote(continuation, safe='')}"
        page = request(path + suffix, token=token)
        if not isinstance(page, dict) or not isinstance(page.get("items"), list):
            raise ValueError("malformed Kubernetes list")
        result.extend(page["items"])
        continuation = page.get("metadata", {}).get("continue", "")
        if not continuation:
            return result
    raise ValueError("Kubernetes pagination limit reached")


def obsolete_owned_apps(apps, appset_uid, eligible):
    obsolete = []
    for app in apps:
        metadata = app.get("metadata", {})
        if metadata.get("namespace") != NAMESPACE:
            continue
        match = APP_NAME.fullmatch(metadata.get("name", ""))
        if not match or int(match.group(1)) in eligible:
            continue
        if not any(ref.get("apiVersion") == "argoproj.io/v1alpha1"
                   and ref.get("kind") == "ApplicationSet"
                   and ref.get("name") == APPSET and ref.get("uid") == appset_uid
                   for ref in metadata.get("ownerReferences", [])):
            continue
        if not metadata.get("uid") or not metadata.get("resourceVersion"):
            raise ValueError("Application missing deletion precondition")
        obsolete.append((int(match.group(1)), metadata))
    return obsolete


def run(request=kubernetes_request, github_request=request_json):
    sa_token = open("/var/run/secrets/kubernetes.io/serviceaccount/token",
                    encoding="utf-8").read().strip()
    gh_token = github_token(os.environ["GITHUB_APP_ID"],
                            os.environ["GITHUB_APP_INSTALLATION_ID"],
                            os.environ["GITHUB_APP_PRIVATE_KEY"], github_request)
    eligible = eligible_numbers(gh_token, github_request)
    base = f"/apis/argoproj.io/v1alpha1/namespaces/{NAMESPACE}"
    appset = request(f"{base}/applicationsets/{APPSET}", token=sa_token)
    appset_uid = appset.get("metadata", {}).get("uid")
    if not appset_uid:
        raise ValueError("ApplicationSet UID missing")
    apps = list_all(f"{base}/applications", sa_token, request)
    for number, metadata in obsolete_owned_apps(apps, appset_uid, eligible):
        if not still_ineligible(number, gh_token, github_request):
            continue
        try:
            request(f"{base}/applications/{metadata['name']}", token=sa_token,
                    method="DELETE", body={"apiVersion": "v1", "kind": "DeleteOptions",
                                           "preconditions": {"uid": metadata["uid"],
                                                             "resourceVersion": metadata["resourceVersion"]}})
        except HTTPError as error:
            # Another reconciler may have updated or deleted the object after
            # our list. Leave that object to the next pass, but keep cleaning
            # unrelated stale Applications in this pass.
            if error.code not in (404, 409):
                raise


if __name__ == "__main__":
    run()
