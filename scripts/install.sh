#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
set -a
. ./.env
set +a
export KUBECONFIG="$PWD/terraform/kubeconfig"

for dir in terraform/k3s terraform/flux; do
  terraform -chdir="$dir" init -input=false
  terraform -chdir="$dir" apply "$@"
done

until kubectl -n vault get pod vault-0 >/dev/null 2>&1; do
  echo "Waiting for Flux to start Vault (progress: flux get kustomizations)"
  sleep 20
done
kubectl -n vault wait pod/vault-0 --for=condition=Ready --timeout=15m

vault() { kubectl -n vault exec vault-0 -- vault "$@"; }
vault_stdin() { kubectl -n vault exec -i vault-0 -- vault "$@"; }
kv() { printf %s "$4" | vault_stdin kv "$1" "secret/apps/$2" "$3=-" >/dev/null; }
status() { vault status -format=json || [ $? -eq 2 ]; }

state=$(status)
if grep -q '"initialized": false' <<<"$state"; then
  init=$(vault operator init -key-shares=1 -key-threshold=1)
  key=$(awk '/^Unseal Key 1:/ {print $4}' <<<"$init")
  token=$(awk '/^Initial Root Token:/ {print $4}' <<<"$init")
  printf '\nUnseal key: %s\nRoot token: %s\n\n' "$key" "$token"
  read -rp "Save both in a password manager. Without the unseal key every secret is lost. Press Enter when done. "
  printf %s "$key" | vault_stdin write sys/unseal key=- >/dev/null
  printf %s "$token" | vault_stdin login - >/dev/null

  vault secrets enable -path=secret kv-v2
  vault auth enable kubernetes
  vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc
  printf '%s\n' 'path "secret/data/apps/*" { capabilities = ["read"] }' | vault_stdin policy write apps-read -
  vault write auth/kubernetes/role/apps bound_service_account_names=vault-reader bound_service_account_namespaces=apps policies=apps-read ttl=1h

  read -rsp "Password of the Postgres role statistics (step 2): " db_statistics && echo
  read -rsp "Password of the Postgres role mon_home_ass (step 2): " db_mon_home_ass && echo
  read -rsp "Password of the statistics-service admin (empty: no local admin): " admin && echo
  nats_statistics=$(openssl rand -hex 24)
  nats_mon_home_ass=$(openssl rand -hex 24)
  kv put nats STATS_SERVICE_PASSWORD "$nats_statistics"
  kv patch nats COLLECTOR_PASSWORD "$(openssl rand -hex 24)"
  kv patch nats MON_HOME_ASS_PASSWORD "$nats_mon_home_ass"
  kv put statistics-service DB_PASSWORD "$db_statistics"
  kv patch statistics-service ADMIN_PASSWORD "$admin"
  kv patch statistics-service OIDC_CLIENT_SECRET ""
  kv patch statistics-service NATS_PASSWORD "$nats_statistics"
  kv put mon-home-ass DB_PASSWORD "$db_mon_home_ass"
  kv patch mon-home-ass NATS_PASSWORD "$nats_mon_home_ass"
  kubectl -n vault exec vault-0 -- sh -c "rm -f \"\$HOME/.vault-token\""
fi

state=$(status)
if grep -q '"sealed": true' <<<"$state"; then
  kubectl -n vault exec -it vault-0 -- vault operator unseal
fi

echo
echo "Done. Flux committed clusters/home/flux-system to main on the first run: git pull."
echo "kubectl in this shell: export KUBECONFIG=$KUBECONFIG"
