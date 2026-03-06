#!/usr/bin/env bash
# ============================================================
# 02-external-secrets.sh — Install External Secrets Operator
#
# HA 설정:
#   - replicas: 2 (HPA min), resources, PDB, TopologySpread
#   - HPA: min 2 / max 4 / CPU 80%
#   - PriorityClass: platform-critical
#
# Usage: ./02-external-secrets.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

echo "[eso] Installing External Secrets Operator on: ${CLUSTER}"

ESO_VERSION="2.0.1"
NAMESPACE="external-secrets"

az aks get-credentials --resource-group "rg-${PREFIX:-k8s}-${CLUSTER}" \
  --name "aks-${CLUSTER}" --overwrite-existing --only-show-errors

# ---- ESO Workload Identity Client ID 자동 조회 ----
# ESO_MI_CLIENT_ID가 환경변수로 주입되지 않은 경우 Azure CLI로 자동 조회
if [[ -z "${ESO_MI_CLIENT_ID:-}" ]]; then
  ESO_MI_CLIENT_ID=$(az identity show \
    --name "mi-eso-${CLUSTER}" \
    --resource-group "rg-${PREFIX:-k8s}-common" \
    --query clientId -o tsv 2>/dev/null || echo "")
  [[ -n "${ESO_MI_CLIENT_ID}" ]] && \
    echo "[eso] ESO_MI_CLIENT_ID 자동 조회: ${ESO_MI_CLIENT_ID}"
fi

helm repo add external-secrets https://charts.external-secrets.io --force-update
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${ESO_VERSION}" \
  --set replicaCount=2 \
  --set priorityClassName=platform-critical \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=64Mi \
  --set resources.limits.cpu=200m \
  --set resources.limits.memory=128Mi \
  --set podDisruptionBudget.enabled=true \
  --set podDisruptionBudget.minAvailable=1 \
  --set 'topologySpreadConstraints[0].maxSkew=1' \
  --set 'topologySpreadConstraints[0].topologyKey=topology.kubernetes.io/zone' \
  --set 'topologySpreadConstraints[0].whenUnsatisfiable=ScheduleAnyway' \
  --set 'topologySpreadConstraints[0].labelSelector.matchLabels.app\.kubernetes\.io/name=external-secrets' \
  --set webhook.replicaCount=2 \
  --set webhook.resources.requests.cpu=25m \
  --set webhook.resources.requests.memory=32Mi \
  --set webhook.resources.limits.cpu=100m \
  --set webhook.resources.limits.memory=64Mi \
  --set certController.resources.requests.cpu=25m \
  --set certController.resources.requests.memory=64Mi \
  --set certController.resources.limits.cpu=100m \
  --set certController.resources.limits.memory=128Mi \
  ${ESO_MI_CLIENT_ID:+--set "serviceAccount.annotations.azure\.workload\.identity/client-id=${ESO_MI_CLIENT_ID}"} \
  ${ESO_MI_CLIENT_ID:+--set "podLabels.azure\.workload\.identity/use=true"} \
  --wait --timeout 10m

# HPA — ESO controller
cat <<'EOF' | kubectl apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: external-secrets
  namespace: external-secrets
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: external-secrets
  minReplicas: 2
  maxReplicas: 4
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 80
EOF

echo "[eso] ✓ Installed v${ESO_VERSION} on ${CLUSTER} (HA + HPA)"

# ---- Azure Key Vault SecretStore (Workload Identity) ----
# 필수 환경변수:
#   KEY_VAULT_URL      : https://<vault-name>.vault.azure.net
#   ESO_MI_CLIENT_ID   : SecretStore용 Workload Identity Client ID
#                        (cert-manager MI와 분리 권장, 최소 권한: Key Vault Secrets User)

if [[ -z "${KEY_VAULT_URL:-}" || -z "${ESO_MI_CLIENT_ID:-}" ]]; then
  echo "[eso] KEY_VAULT_URL / ESO_MI_CLIENT_ID 미설정 — SecretStore 생성 건너뜀"
  echo "[eso] SecretStore를 구성하려면 addon_env에 위 변수를 추가하세요."
  exit 0
fi

: "${AZURE_TENANT_ID:?AZURE_TENANT_ID 환경변수를 설정하세요}"

echo "[eso] Creating Azure Key Vault ClusterSecretStore on ${CLUSTER}"

# ESO webhook이 준비될 때까지 대기
kubectl -n "${NAMESPACE}" wait --for=condition=Available deployment/external-secrets-webhook --timeout=120s

# ClusterSecretStore — Azure Key Vault + Workload Identity
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: azure-keyvault
spec:
  provider:
    azurekv:
      authType: WorkloadIdentity
      vaultUrl: "${KEY_VAULT_URL}"
      serviceAccountRef:
        name: external-secrets
        namespace: "${NAMESPACE}"
EOF

# ServiceAccount에 Workload Identity 어노테이션 추가
kubectl annotate serviceaccount external-secrets \
  -n "${NAMESPACE}" \
  azure.workload.identity/client-id="${ESO_MI_CLIENT_ID}" \
  --overwrite

# ExternalSecret 예시 (참고용 — 실제 시크릿 이름에 맞게 수정)
cat <<'EOF' | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: example-secret
  namespace: default
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: azure-keyvault
    kind: ClusterSecretStore
  target:
    name: example-secret
    creationPolicy: Owner
  data:
    - secretKey: my-key
      remoteRef:
        key: my-kv-secret-name   # Key Vault 시크릿 이름
EOF

echo "[eso] ✓ ClusterSecretStore 'azure-keyvault' created on ${CLUSTER}"
echo "[eso] ExternalSecret 예시가 default 네임스페이스에 생성되었습니다 (수정 후 사용)"
