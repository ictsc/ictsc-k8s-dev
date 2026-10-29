# Regalia PR preview (draft)

The proposed ApplicationSet in `manifest/envs/dev/resources/regalia-pr-preview.yaml`
is intentionally **not referenced** by the dev kustomization. The current chart
creates an isolated namespace, PostgreSQL cluster, Valkey, and demo-mode app.
It creates no HTTPRoute or ListenerSet, so no PR URL is live yet.

## Activation gates

1. Provision a read-only GitHub App token for ApplicationSet in the existing
   secret manager and expose it as `argocd/regalia-pr-preview-github` (`token`).
   No token value belongs in Git.
2. Validate Cilium 1.20.1 ListenerSet CRDs and controller support on the dev
   cluster. Add `allowedListeners` to the shared Gateway, then use one
   ListenerSet and HTTP-01 Certificate per PR namespace. Confirm TLS Secret
   discovery and HTTPRoute parent attachment on a disposable test namespace.
3. Add an outer auth path with a trusted proxy that filters incoming Cookie,
   Authorization and identity headers before PR code. The proxy must allow
   only Regalia session cookie names
   (`regalia-user-session`, `admin-session`, `signup-session`,
   `oauth2-session`, `admin-oauth2-session`) and must filter response
   `Set-Cookie`, `Clear-Site-Data`, and other privileged headers. Test with a
   malicious PR image. The existing `.k8s-dev.ictsc.net` oauth2-proxy cookie
   reaches PR subdomains, so host-only application cookies do not solve this.
4. Verify HTTPS and auth on the real URL, including first HTTP-01 issuance,
   commit updates, label removal, PR close, namespace and PVC deletion. Only
   then add the ApplicationSet resource to `manifest/envs/dev/kustomization.yaml`
   and allow a Ready comment after Pod and URL checks.

The ApplicationSet reads only `number` and `head_sha` from the PR generator.
Its repo, project, chart path and destination server are fixed. A removed
label or closed PR removes the generated Application; its finalizer is intended
to prune the namespace and namespaced resources. This teardown needs live
verification before activation. The chart's ResourceQuota limits CPU, memory,
storage and pod count per preview, but a separate cap on concurrent preview
count is still required.

The image workflow lives in `ictsc-regalia`. PR code builds with read-only
permissions and produces OCI archives. A trusted `workflow_run` job checks the
run and current PR state and publishes fixed image names tagged with PR number
and full head SHA. The publisher never checks out PR code. Only same-repository
PRs are accepted for now; fork PRs fail closed. The publisher's tag immutability
and lifecycle races need a real workflow run before activation.

## Validation before merge

Run `helm template preview manifest/base/apps/regalia/pr-preview --set
prNumber=123 --set headSHA=<40 lowercase hex digits>` and validate the output
against the dev cluster API. Run `kustomize build manifest/envs/dev` and confirm
that neither the new ApplicationSet nor any new route is active. Inspect the
GitHub Actions workflow runs and publish an image from a disposable labeled PR.
Do not infer URL readiness from a successful image build.
