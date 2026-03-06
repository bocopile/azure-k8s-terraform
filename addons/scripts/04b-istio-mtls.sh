#!/usr/bin/env bash
# ============================================================
# 04b-istio-mtls.sh — Istio mTLS STRICT 모드 구성
#
# 04-istio.sh (az aks mesh enable) 실행 완료 후 적용해야 합니다.
# 아키텍처 명세: ARCHITECTURE.md §5.4 mTLS STRICT
#
# 적용 내용:
#   1. 네임스페이스에 istio.io/rev=asm-1-28 레이블 추가 (사이드카 주입)
#   2. 메시 전체 PeerAuthentication STRICT (istio-system 네임스페이스)
#   3. 메시 전체 DestinationRule ISTIO_MUTUAL
#
# Usage: ./04b-istio-mtls.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"
REVISION="${REVISION:-asm-1-28}"

echo "[istio-mtls] Configuring mTLS STRICT on: ${CLUSTER} (revision=${REVISION})"

az aks get-credentials --resource-group "rg-${PREFIX:-k8s}-${CLUSTER}" \
  --name "aks-${CLUSTER}" --overwrite-existing --only-show-errors

# ---- 1. 네임스페이스 레이블 — 사이드카 주입 활성화 ----
# kube-system, kube-public, kube-node-lease 제외한 사용자 네임스페이스 전체 레이블링
echo "[istio-mtls] Labeling namespaces for sidecar injection..."

SKIP_NS="kube-system|kube-public|kube-node-lease|default"
for ns in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}'); do
  if echo "${ns}" | grep -qvE "^(${SKIP_NS})$"; then
    kubectl label namespace "${ns}" istio.io/rev="${REVISION}" --overwrite
    echo "[istio-mtls]   labeled: ${ns}"
  fi
done

# default 네임스페이스도 레이블링 (워크로드가 있을 경우 대비)
kubectl label namespace default istio.io/rev="${REVISION}" --overwrite

echo "[istio-mtls] Namespace labeling complete."

# ---- 2. 메시 전체 PeerAuthentication — STRICT mTLS ----
# istio-system 네임스페이스에 selector 없이 생성 → 메시 전체 정책 (mesh-wide)
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
EOF

echo "[istio-mtls] PeerAuthentication STRICT applied (mesh-wide)."

# ---- 3. 메시 전체 DestinationRule — ISTIO_MUTUAL ----
# host: "*.local" → 클러스터 내 모든 서비스 적용
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: default
  namespace: istio-system
spec:
  host: "*.local"
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
EOF

echo "[istio-mtls] DestinationRule ISTIO_MUTUAL applied (mesh-wide)."
echo "[istio-mtls] ✓ mTLS STRICT configured on ${CLUSTER}"
echo "[istio-mtls] NOTE: 기존 파드는 재시작해야 사이드카가 주입됩니다."
echo "[istio-mtls]   kubectl rollout restart deployment -n <namespace>"
