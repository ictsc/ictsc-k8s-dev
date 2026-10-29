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

## Trust boundary

`ictsc-regalia` builds backend, frontend, and migrations OCI artifacts in a
read-only `pull_request` workflow, including forks. A trusted default-branch
`workflow_run` validates GitHub's run, workflow ID/path, current PR head SHA,
open state, preview label, and all three artifact IDs/digests before copying to
fixed GHCR tags. It does not check out or execute PR code. The publisher
checks raw manifest bytes before reusing an existing tag and verifies the
copied manifest. A disposable fork PR must verify GitHub's workflow-run PR
association and artifact download before activation.

The proxy is built only from `ictsc-k8s-dev` main. It checks the parent-domain
Regalia OAuth cookie with the trusted `regalia-auth` service. Unauthenticated
users go to the **existing fixed** `contest.k8s-dev.ictsc.net/oauth2/start`
callback route with `rd` fixed to their PR hostname. The proxy forwards only
specified non-identity headers and the Regalia application session cookie names
to PR code. It rebuilds allowlisted response cookies as Secure, HttpOnly,
SameSite=Strict, host-only cookies and removes `Clear-Site-Data`. The PR image
never receives the parent-domain OAuth cookie or identity headers. Test this
boundary with a malicious app image and OAuth redirect flow on a disposable PR.

Only the migration init container uses the PR-supplied migrations image; it
receives no database password or service-account token and copies SQL into a
shared volume. A fixed `postgres:16-alpine` runner applies numbered migrations
in order, checks stored SHA-256 checksums on head updates, and seeds an empty
preview DB from the PR's `seed-dev.sql`. It fails if psql errors or an existing
migration changes. An interrupted migration between SQL apply and ledger insert
requires deleting the disposable PR namespace and recreating it. Fake Discord
login uses the seeded `preview-contestant` account and sample problems.

## Activation gates

1. Provision `argocd/regalia-pr-preview-github-app` from existing secret
   management in GitHub App repo-creds format with read-only PR access.
   ApplicationSet's `appSecretName` mints short-lived installation tokens.
2. Confirm Cilium 1.20.1 ListenerSet CRD is installed and the operator has
   detected it. Cilium documents an operator restart if the CRD was installed
   afterward. Apply the Gateway patch only after verifying it permits selected
   PR namespaces and leaves existing listeners and routes intact.
3. Confirm the actual cluster DNS service IP. The chart's proposed value is
   `10.96.0.10` from the configured `10.96.0.0/12` service range; it has not
   been observed live. Confirm CNPG operator, DNS, auth and Gateway traffic
   through the NetworkPolicies before enabling exposure.
4. Add an enforced **cluster-wide cap** on active previews. Per-namespace
   ResourceQuota alone does not limit the number of PR namespaces. The current
   ApplicationSet has no global cap, so it must remain inactive.
5. Run a disposable PR end to end: image build, fake contestant login, known
   sample problem, cert-manager HTTP-01 first issuance, TLS ListenerSet
   Accepted/Programmed, auth redirect and malicious-header tests, commit
   update/migration, label removal, PR close, Application/namespace/PVC teardown.
   Verify Pod health and HTTP response before posting any Ready comment.
6. Only after these gates pass, add the ApplicationSet to
   `manifest/envs/dev/kustomization.yaml` and explicitly set exposure true in
   its fixed Helm parameters. No new Cloudflare key or DNS change is expected.

Cilium ListenerSet behavior is documented in its
[v1.20.1 guide](https://github.com/cilium/cilium/blob/v1.20.1/Documentation/network/servicemesh/gateway-api/listenerset.rst).
The [Argo CD PR generator documentation](https://argo-cd.readthedocs.io/en/latest/operator-manual/applicationset/Generators-Pull-Request/)
describes `appSecretName`, `head_sha` and label-driven removal.
