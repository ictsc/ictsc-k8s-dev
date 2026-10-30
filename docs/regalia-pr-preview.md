# Regalia PR preview activation

The dev overlay activates `manifest/envs/dev/resources/regalia-pr-preview.yaml`
with a dedicated, single-namespace ApplicationSet controller in
`regalia-preview-control`. The chart defaults to `enableExposure: false`, but
the trusted ApplicationSet passes a boolean `true`. A namespace-scoped quota
allows two generated Applications while the separate #3500 smoke test remains
live; raise this to three only after #3500 is normally removed. The controller
does not use Argo CD's multi-namespace ApplicationSet mode or receive
cluster-wide Secret read permission.

The existing Sakura ClusterSecretStore allows the control namespace so ESO can
materialize the same read-only GitHub App credential there. This namespace
admission permits a trusted ExternalSecret author in that namespace to request
other names from the same vault; do not give PR workloads or untrusted users
permission to create ExternalSecrets there. The AppSet controller can read
Secrets only in its own namespace. Existing `argocd` app controller and server
need `application.namespaces: regalia-preview-control` and a controlled restart
after the Helm values sync; the shared AppSet controller remains unchanged.

The Gateway admits ListenerSets only from chart-managed preview namespaces
with both preview labels. The cleanup image is pinned to the digest published
from main. Its CronJob only deletes obsolete Applications owned by the
permanent AppSet; Argo's resources finalizer performs workload and PVC cleanup.
The Regalia publisher variable must be enabled separately for new head images.
Until then, a label alone will not produce a new image.

The chart supplies one namespace, dedicated CNPG PostgreSQL and Valkey, quota,
app, migration Job, and scoped NetworkPolicies per PR. The trusted proxy,
HTTP-01 Certificate, ListenerSet, and routes are rendered only when
`enableExposure` is deliberately set true. The dev Kustomize overlay applies the shared Gateway selector for chart-managed preview namespaces.

## Quota and cleanup behavior

The dedicated source namespace has a quota of two Application objects while
#3500 is maintained by a separate test AppSet. Increase it to three only after
that test is removed. Kubernetes quota admission is the atomic capacity limit.
Argo CD v3.5.0 creates before deleting during AppSet reconcile: at capacity,
a waiting PR can prevent an obsolete Application from being removed. On
2026-10-29, this failure was reproduced with the real v3.5.0 controller in an
isolated dev namespace. The cleanup CronJob rechecks GitHub state and deletes
only obsolete Applications with the expected controlling AppSet owner UID;
Argo's resources finalizer remains responsible for workload teardown. The
cleanup image was published from main on 2026-10-30 and pinned by digest.
Its unit tests cover pagination, fail-closed GitHub responses, ownership,
relabel races, deletion preconditions and conflicts. A full quota-saturation
and cleanup run with real GitHub PRs remains an activation verification step.

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

## Operational checks

1. Keep #3500 under its temporary AppSet until the user finishes viewing it.
   Its `preview` label is removed so the permanent AppSet cannot create a
   second Application for the same namespace. The separate test label remains.
2. Sync the control namespace, namespace-scoped RBAC, ESO credential,
   AppProjects, dedicated controller and cleanup CronJob. Confirm ESO Ready,
   controller Ready, no all-namespace Secret access, and a successful GitHub
   PR generator poll. The shared AppSet controller stays unchanged. Sync the
   Argo Helm value `application.namespaces: regalia-preview-control` and then
   roll the application controller and server to pick it up.
3. Confirm #3500 remains HTTPS-valid and redirects unauthenticated requests
   to Dex after the Gateway selector changes. Check both ListenerSet status
   and the Gateway's existing contest routes. The fixed proxy forwards no
   OAuth session cookie or identity header to PR workloads.
4. Enable `ENABLE_PR_PREVIEW_PUBLISH=true` only after the duplicate-build fix
   and trusted-operator publication scope are reviewed. The publisher's bot
   comment confirms image publication and shows the expected URL; it does not
   claim Argo or application health.
5. Verify two generated PRs plus a third waiting while #3500 exists, then
   remove a label or close one admitted PR. Confirm cleanup frees the quota
   slot, the waiting PR is generated, and the removed PR's Application,
   namespace, PVC, PV and Longhorn volume disappear normally. Exercise a head
   update. Stop activation on unauthorized exposure, failed finalizer/PVC
   teardown, or controller permissions that require cluster-wide Secret reads.
6. Once #3500 is closed and fully removed, delete its temporary AppSet and
   AppProject and raise the permanent quota from two to three. Arbitrary PR
   JavaScript on this parent domain remains unsafe: a trusted operator must
   review code before labeling it, and untrusted fork heads must not be
   published without a separate isolation design.

Cilium ListenerSet behavior is documented in its
[v1.20.1 guide](https://github.com/cilium/cilium/blob/v1.20.1/Documentation/network/servicemesh/gateway-api/listenerset.rst).
The [Argo CD PR generator documentation](https://argo-cd.readthedocs.io/en/latest/operator-manual/applicationset/Generators-Pull-Request/)
describes `appSecretName`, `head_sha` and label-driven removal. The
[ApplicationSet in any namespace guide](https://argo-cd.readthedocs.io/en/latest/operator-manual/applicationset/Appset-Any-Namespace/)
describes the additional controls needed for a dedicated quota namespace.
