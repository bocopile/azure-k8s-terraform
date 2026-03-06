#!/usr/bin/env bash
# ============================================================
# 01-cert-manager.sh — Install cert-manager v1.19.x on mgmt cluster
#
# HA 설정:
#   - replicas: 2 (HPA min), resources, PDB, TopologySpread
#   - HPA: min 2 / max 4 / CPU 80%
#   - PriorityClass: platform-critical
#
# Usage: ./01-cert-manager.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

echo "[cert-manager] Installing on cluster: ${CLUSTER}"

CERT_MANAGER_VERSION="v1.19.4"
NAMESPACE="cert-manager"

az aks get-credentials --resource-group "rg-${PREFIX:-k8s}-${CLUSTER}" \
  --name "aks-${CLUSTER}" --overwrite-existing --only-show-errors

# ---- cert-manager Workload Identity Client ID 자동 조회 ----
# CERT_MANAGER_CLIENT_ID가 환경변수로 주입되지 않은 경우 Azure CLI로 자동 조회
if [[ -z "${CERT_MANAGER_CLIENT_ID:-}" ]]; then
  CERT_MANAGER_CLIENT_ID=$(az identity show \
    --name "mi-cert-manager-${CLUSTER}" \
    --resource-group "rg-${PREFIX:-k8s}-common" \
    --query clientId -o tsv 2>/dev/null || echo "")
  [[ -n "${CERT_MANAGER_CLIENT_ID}" ]] && \
    echo "[cert-manager] CERT_MANAGER_CLIENT_ID 자동 조회: ${CERT_MANAGER_CLIENT_ID}"
fi

helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${CERT_MANAGER_VERSION}" \
  --set installCRDs=true \
  --set global.leaderElection.namespace="${NAMESPACE}" \
  --set global.priorityClassName=platform-critical \
  --set replicaCount=2 \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=64Mi \
  --set resources.limits.cpu=200m \
  --set resources.limits.memory=128Mi \
  --set podDisruptionBudget.enabled=true \
  --set podDisruptionBudget.minAvailable=1 \
  --set 'topologySpreadConstraints[0].maxSkew=1' \
  --set 'topologySpreadConstraints[0].topologyKey=topology.kubernetes.io/zone' \
  --set 'topologySpreadConstraints[0].whenUnsatisfiable=ScheduleAnyway' \
  --set 'topologySpreadConstraints[0].labelSelector.matchLabels.app\.kubernetes\.io/name=cert-manager' \
  --set webhook.replicaCount=2 \
  --set webhook.resources.requests.cpu=25m \
  --set webhook.resources.requests.memory=32Mi \
  --set webhook.resources.limits.cpu=100m \
  --set webhook.resources.limits.memory=64Mi \
  --set cainjector.resources.requests.cpu=25m \
  --set cainjector.resources.requests.memory=64Mi \
  --set cainjector.resources.limits.cpu=100m \
  --set cainjector.resources.limits.memory=128Mi \
  ${CERT_MANAGER_CLIENT_ID:+--set "serviceAccount.annotations.azure\.workload\.identity/client-id=${CERT_MANAGER_CLIENT_ID}"} \
  ${CERT_MANAGER_CLIENT_ID:+--set "podLabels.azure\.workload\.identity/use=true"} \
  --wait --timeout 10m

# Workload Identity 구성 확인
if [[ -n "${CERT_MANAGER_CLIENT_ID:-}" ]]; then
  echo "[cert-manager] Workload Identity 구성됨 — Client ID: ${CERT_MANAGER_CLIENT_ID}"
  echo "[cert-manager] SA 어노테이션 확인:"
  kubectl get sa cert-manager -n "${NAMESPACE}" \
    -o jsonpath='{.metadata.annotations}' 2>/dev/null | grep -o 'azure\.workload\.identity[^,]*' || true
else
  echo "[cert-manager] CERT_MANAGER_CLIENT_ID 미설정 — Workload Identity 미구성"
  echo "[cert-manager] DNS-01 챌린지 사용 시 addon_env에 CERT_MANAGER_CLIENT_ID를 추가하세요."
fi

# HPA — cert-manager controller
cat <<'EOF' | kubectl apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: cert-manager
  namespace: cert-manager
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: cert-manager
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

# ---- ClusterIssuer — Let's Encrypt (DNS-01 / Azure DNS) ----
# 필수 환경변수:
#   LETSENCRYPT_EMAIL       : 인증서 만료 알림 수신 이메일 (필수)
#   AZURE_SUBSCRIPTION_ID   : DNS Zone이 위치한 구독 ID
#   AZURE_TENANT_ID         : Azure AD Tenant ID
#   DNS_ZONE_RG             : Azure DNS Zone 리소스 그룹
#   DNS_ZONE_NAME           : Azure DNS Zone 이름 (예: example.com)
#   CERT_MANAGER_CLIENT_ID  : cert-manager Workload Identity 클라이언트 ID
#
# DNS Zone이 없으면 HTTP-01 ClusterIssuer만 생성됩니다.

: "${LETSENCRYPT_EMAIL:?LETSENCRYPT_EMAIL 환경변수를 설정하세요 (예: admin@example.com)}"
: "${AZURE_SUBSCRIPTION_ID:?AZURE_SUBSCRIPTION_ID 환경변수를 설정하세요}"
: "${AZURE_TENANT_ID:?AZURE_TENANT_ID 환경변수를 설정하세요}"

echo "[cert-manager] Creating ClusterIssuer resources..."

# cert-manager가 완전히 준비될 때까지 대기
kubectl -n "${NAMESPACE}" wait --for=condition=Available deployment/cert-manager --timeout=120s

if [[ -n "${DNS_ZONE_NAME:-}" && -n "${DNS_ZONE_RG:-}" && -n "${CERT_MANAGER_CLIENT_ID:-}" ]]; then
  # DNS-01 ClusterIssuer (Workload Identity + Azure DNS)
  cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${LETSENCRYPT_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging-key
    solvers:
      - dns01:
          azureDNS:
            subscriptionID: ${AZURE_SUBSCRIPTION_ID}
            resourceGroupName: ${DNS_ZONE_RG}
            hostedZoneName: ${DNS_ZONE_NAME}
            environment: AzurePublicCloud
            managedIdentity:
              clientID: ${CERT_MANAGER_CLIENT_ID}
EOF

  cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-production
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${LETSENCRYPT_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-production-key
    solvers:
      - dns01:
          azureDNS:
            subscriptionID: ${AZURE_SUBSCRIPTION_ID}
            resourceGroupName: ${DNS_ZONE_RG}
            hostedZoneName: ${DNS_ZONE_NAME}
            environment: AzurePublicCloud
            managedIdentity:
              clientID: ${CERT_MANAGER_CLIENT_ID}
EOF
  echo "[cert-manager] ✓ DNS-01 ClusterIssuer (staging + production) created"
else
  # HTTP-01 ClusterIssuer fallback (인터넷에서 접근 가능한 인그레스 필요)
  echo "[cert-manager] DNS_ZONE_NAME / CERT_MANAGER_CLIENT_ID 미설정 — HTTP-01 ClusterIssuer 생성"
  cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${LETSENCRYPT_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
EOF

  cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-production
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${LETSENCRYPT_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-production-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
EOF
  echo "[cert-manager] ✓ HTTP-01 ClusterIssuer (staging + production) created"
fi

echo "[cert-manager] ✓ Installed ${CERT_MANAGER_VERSION} on ${CLUSTER} (HA + HPA)"
