#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
action="${1:?usage: omni-prod.sh terraform|kubeconfig [arguments]}"
shift
unset OMNI_SERVICE_ACCOUNT_KEY
source "$root/.omni/prod-omni.env"
: "${OMNI_SERVICE_ACCOUNT_KEY:?Missing prod Omni service account key}"
export OMNI_SERVICE_ACCOUNT_KEY OMNI_ENDPOINT=https://omni.ictsc.net
case "$action" in
  terraform)
    # This root has its own backend key and uses only the default workspace.
    export TF_WORKSPACE=default
    exec terraform -chdir="$root/omni/clusters/prod" "$@"
    ;;
  kubeconfig)
    umask 077
    exec "$root/bin/omnictl" kubeconfig "$root/.kube/prod" \
      --cluster ictsc-prod --merge=false --force \
      --service-account --user terraform-ictsc-prod --ttl 1h
    ;;
  *) echo 'Expected terraform or kubeconfig' >&2; exit 2 ;;
esac
