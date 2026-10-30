# Regalia PR preview activation

The ApplicationSet in `manifest/envs/dev/resources/regalia-pr-preview.yaml` is
**not referenced** by the dev kustomization. The chart has `enableExposure: false`
by default. No PR URL is currently live, and merging this draft does not change
the shared Gateway, contest, scoreserver, OAuth proxy, or DNS.

The chart supplies one namespace, dedicated CNPG PostgreSQL and Valkey, quota,
app, migration Job, and scoped NetworkPolicies per PR. The trusted proxy,
HTTP-01 Certificate, ListenerSet, and routes are rendered only when
`enableExposure` is deliberately set true. The shared Gateway's
`allowedListeners` patch is in `activation/gateway-listenerset-patch.yaml` and
is not part of the dev kustomization.

The inactive ApplicationSet proposal now lives in a dedicated
`regalia-preview-control` source namespace. A ResourceQuota admits at most
three `Application` objects there, including concurrent create requests.
Existing Applications keep their quota slots while excess PRs are rejected;
removing a label or closing a PR releases a slot after Application deletion.
GitHub's open/`preview` PR set is selected by one ApplicationSet generator;
Kubernetes quota admission is the single authority for capacity. At capacity,
the ApplicationSet reports a quota error for pending PRs. **This proposal
cannot be activated as-is.** Argo CD 3.5 stops its ApplicationSet reconcile
after a create error, before deleting obsolete Applications. With three
admitted PRs and a fourth pending, closing an admitted PR leaves its old
Application in place while creation of the fourth keeps failing. The kind
test below proves the atomic admission cap only; it does not test Argo's
reconciliation lifecycle.

On 2026-10-29, an isolated dev namespace ran the actual Argo CD v3.5.0
ApplicationSet controller with the installed Application CRD and a three-App
quota. A credential-free list generator created three Apps; a fourth failed
admission. Removing one incumbent from the generator did not delete it because
the fourth create failed first. Manually deleting the stale App freed the slot
only after its resources finalizer was cleared; that isolated controller had
no Application controller to finish deletion. This reproduces the proposed
cleanup's need but does not validate the cleanup Job or a real PR generator.

The inactive `activation/cleanup.yaml` provides a small trusted cleanup
CronJob in Argo's namespace. It
must list the ApplicationSet-owned Applications in the dedicated source
namespace, fetch the current open, `preview`-labeled PR numbers via the same
GitHub App, and delete only Applications whose PR is no longer eligible. It
must fail without deleting anything if the GitHub response is incomplete or
unavailable, and recheck a PR immediately before deletion. Give it only
list/get/delete Application RBAC in the source namespace and read access to
the existing GitHub App credential. Run it at most once concurrently. This
preserves ApplicationSet generation: once an obsolete Application finishes
deleting, a retry of the ApplicationSet reconcile can admit the next PR.
The ResourceQuota remains the atomic limit under concurrent events. This is
smaller than a replacement controller or generator plugin because it only
removes stale objects; a plugin alone cannot change Argo's create-before-delete
order. The Python code has unit tests for complete pagination, fail-closed
responses, ownership, namespace isolation, relabel recheck, deletion
preconditions, and conflict continuation. A PR can be relabeled or reopened
after the last GitHub check and before Kubernetes accepts DELETE; that rare
cross-system race can delete and then recreate its disposable preview. The image
is published only through the trusted main-branch `Preview cleanup` manual
workflow; it has not been published or deployed. Test three admitted plus one
pending with the GitHub generator and cleanup Job, plus label removal, close,
head update, simultaneous events, and interrupted deletion before activation.
Cleanup sends DELETE but never bypasses the resources finalizer. If the
Application controller cannot finish deletion, the quota slot stays occupied;
the next cleanup run retries DELETE and does not force-remove the finalizer.
The live finalizer/PVC check below used a separate Application in `argocd`.
The separate Argo CD any-namespace settings in
`activation/argocd-namespace-values.yaml` are **not loaded** by dev.

## Controlled dev smoke test (2026-10-30)

An isolated AppSet and AppProject in the existing `argocd` namespace selected
only the disposable Regalia PR #3499. The trusted publisher built and pushed
backend, frontend, and migrations images. The generated Application created a
CNPG database, 1Gi Longhorn PVC, Valkey, and app workloads. With exposure
enabled for this PR only, cert-manager issued a valid certificate; the
ListenerSet and routes were accepted, HTTP redirected to HTTPS, and
unauthenticated HTTPS requests redirected to the existing Dex login flow.
Authenticated page rendering was **not verified** because the browser reached a
Dex consent screen requiring user action. The test did not activate the
permanent three-Application quota or cleanup CronJob.

Two container startup failures required live test-only numeric UID patches:
Valkey's entrypoint called `setpriv` and failed `setresuid` with all capabilities
dropped until the pod ran as UID/GID 999; the proxy image declared the
non-numeric `nonroot` user, so kubelet could not prove `runAsNonRoot` until the
pod ran as UID/GID 65532. The chart and proxy Dockerfile now set these numeric
IDs. A second publish run for the same PR head failed closed on an OCI digest
mismatch after two label events started separate builds; this needs a separate
publisher workflow fix and must not be solved by weakening digest comparison.

After the test, PR #3499 was closed and unlabeled. Its Application, namespace,
PVC, PV, and Longhorn volume were removed by normal Argo finalizer cleanup.
The temporary AppSet, AppProject, Gateway allowance, and publisher variable
were removed; existing Argo applications returned to Synced/Healthy. Published
OCI images remain in GHCR.

## Trust boundary

`ictsc-regalia` builds backend, frontend, and migrations OCI artifacts in a
read-only `pull_request` workflow, including forks. A trusted default-branch
`workflow_run` validates GitHub's run, workflow ID/path, current PR head SHA,
open state, preview label, and all three artifact IDs/digests before copying to
fixed GHCR tags. It does not check out or execute PR code. The publisher
checks raw manifest bytes before reusing an existing tag and verifies the
copied manifest. A disposable fork PR must verify GitHub's workflow-run PR
association and artifact download before activation. The trusted publisher
job is gated by `ENABLE_PR_PREVIEW_PUBLISH=true` in the Regalia repository;
without that variable it skips and writes no PR images to GHCR.

The proxy is built only from `ictsc-k8s-dev` main. It checks the parent-domain
Regalia OAuth cookie with the trusted `regalia-auth` service. Unauthenticated
users go to the **existing fixed** `contest.k8s-dev.ictsc.net/oauth2/start`
callback route with `rd` fixed to their PR hostname. The proxy forwards only
specified non-identity headers and the Regalia application session cookie names
to PR code. It rebuilds allowlisted response cookies as Secure, HttpOnly,
SameSite=Strict, host-only cookies and removes `Clear-Site-Data`. The PR image
never receives the parent-domain OAuth cookie or identity headers. **This does
not isolate sibling hosts from PR JavaScript:** a script on
`pr-N.k8s-dev.ictsc.net` can set new cookies with
`Domain=k8s-dev.ictsc.net`, potentially shadowing or flooding cookies sent to
`contest.k8s-dev.ictsc.net`. HttpOnly protects existing values from reading,
but does not prevent such writes. The current same-site hostname therefore
remains an activation blocker for arbitrary PR code. Test it in a browser by
writing a parent-domain cookie from the PR page and observing the Cookie header
at a disposable sibling endpoint. Options require a separately reviewed
browser isolation design, such as an opaque-origin sandbox with a tested API
bridge, or a separate registrable site for the untrusted app with the requested
PR URL serving only a trusted entry page. Neither option is implemented here.

Only the migration init container uses the PR-supplied migrations image; it
receives no database password or service-account token and copies SQL into a
shared volume. A fixed `postgres:16-alpine` runner applies numbered migrations
in order, checks stored SHA-256 checksums on head updates, and seeds an empty
preview DB from the PR's `seed-dev.sql`. A changed or removed migration resets
only the disposable PR database schema before replay. It fails if psql errors.
An interrupted multi-statement migration may require deleting the disposable
PR namespace and recreating it. Fake Discord
login uses the seeded `preview-contestant` account and sample problems.

## Activation gates

1. Provision `argocd/regalia-pr-preview-github-app` from existing secret
   management in GitHub App repo-creds format with read-only PR access.
   Argo CD 3.5 resolves native `appSecretName` from its control namespace,
   even when the ApplicationSet lives elsewhere. ApplicationSet mints
   short-lived installation tokens.
2. Temporarily set `ENABLE_PR_PREVIEW_PUBLISH=true` for a disposable PR test,
   then turn it off until all activation gates pass. This repository variable
   is a separate action, not changed by merging these PRs.
3. Confirm Cilium 1.20.1 ListenerSet CRD is installed and the operator has
   detected it. Cilium documents an operator restart if the CRD was installed
   afterward. Apply the Gateway patch only after verifying it permits selected
   PR namespaces and leaves existing listeners and routes intact.
4. Confirm the actual cluster DNS service IP. The chart's proposed value is
   `10.96.0.10` from the configured `10.96.0.0/12` service range; it has not
   been observed live. Confirm CNPG operator, DNS, auth and Gateway traffic
   through the NetworkPolicies before enabling exposure. Cilium Gateway uses
   the reserved `ingress` identity rather than a Pod identity in `gateway`.
   A CiliumNetworkPolicy permits only `ingress` and `host` (for the kubelet
   TCP probe) to reach proxy port 8080; the proxy authenticates every path.
   Backend, frontend, migration and Valkey remain policy-scoped.
5. Review and enable the **dedicated Argo CD source namespace** settings from
   `activation/argocd-namespace-values.yaml` only after checking Argo CD's
   cluster RBAC, UI/RBAC exposure, secret access and controller restart order.
   Chart 10.2.3 also requires `applicationSet.allowAnyNamespace: true` to
   render the cross-namespace ApplicationSet RBAC; the inactive overlay sets
   it for review.
   The source namespace has a hard quota of three Application CRs. The
   disposable kind test creates eight native Lease objects and eight
   `argoproj.io/v1alpha1` Application objects against the proposed count keys.
   Each admits only three concurrent creates and preserves incumbents until a
   slot is freed. The Application test also holds deletion with Argo's
   resources finalizer and checks that the quota slot remains occupied until
   finalizer removal. The test installs a minimal Argo-compatible CRD, not the
   exact Argo 3.5 CRD or controller. A short 5s quota resync is configured
   only in kind because the production controller's default resync period is
   5m; the earlier 180s CI failures were consistent with that delay. Dev
   verified admission with the installed Argo CRD and reproduced the Argo CD
   3.5 create-before-delete failure with a separate controller and list
   generator. Publish the trusted cleanup image,
   review and add `activation/cleanup.yaml`, then test the cleanup Job with
   Argo before activation. This CI has not installed Argo CD 3.5: fetching
   `https://argoproj.github.io/argo-helm/index.yaml` from the implementation
   environment returned HTTP 403. Do not substitute the minimal CRD test for
   the real controller lifecycle test.
   A separate manual-sync dev Application selected only the chart's Namespace
   and CNPG Cluster with `enableExposure` set to boolean `false`. CNPG became
   healthy and bound a 1Gi `longhorn-single-replica` PVC. Deleting that
   Application with Argo's resources finalizer removed the Application,
   namespace, CNPG Cluster, PVC, PV, and Longhorn volume. No preview route or
   certificate was created. This did not test the full chart or AppSet-driven
   deletion. Pass a boolean Helm value for `enableExposure`: forcing the
   string `"false"` makes the chart render exposure resources.
6. Resolve the same-site JavaScript cookie-writing boundary before exposing
   arbitrary PR app code. Do not treat the proxy's header filter as complete
   browser-origin isolation.
7. Run a disposable PR end to end: image build, fake contestant login, known
   sample problem, cert-manager HTTP-01 first issuance, TLS ListenerSet
   Accepted/Programmed, auth redirect and malicious-header tests, commit
   update/migration, label removal, PR close, Application/namespace/PVC teardown.
   Verify Pod health and HTTP response before posting any Ready comment.
8. Only after these gates pass, add the ApplicationSet to
   `manifest/envs/dev/kustomization.yaml` and explicitly set exposure true in
   its fixed Helm parameters. No new Cloudflare key or DNS change is expected.

Cilium ListenerSet behavior is documented in its
[v1.20.1 guide](https://github.com/cilium/cilium/blob/v1.20.1/Documentation/network/servicemesh/gateway-api/listenerset.rst).
The [Argo CD PR generator documentation](https://argo-cd.readthedocs.io/en/latest/operator-manual/applicationset/Generators-Pull-Request/)
describes `appSecretName`, `head_sha` and label-driven removal. The
[ApplicationSet in any namespace guide](https://argo-cd.readthedocs.io/en/latest/operator-manual/applicationset/Appset-Any-Namespace/)
describes the additional controls needed for a dedicated quota namespace.
