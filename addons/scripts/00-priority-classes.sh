#!/usr/bin/env bash
# ============================================================
# 00-priority-classes.sh — PriorityClass 리소스 설치
#
# 실행 순서: Phase 2 가장 먼저 (addon 스케줄링 우선순위 확보)
# 대상: 전체 클러스터 (mgmt, app1, app2)
#
# PriorityClass 목록:
#   - platform-critical   : Istio, cert-manager, Flux 등 플랫폼 컴포넌트
#   - workload-high       : 앱 워크로드 고우선순위
#   - workload-default    : 일반 워크로드
#
# Usage: ./00-priority-classes.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

echo "[priority-classes] Applying to cluster: ${CLUSTER}"

az aks get-credentials --resource-group "rg-k8s-demo-${CLUSTER}" \
  --name "aks-${CLUSTER}" --overwrite-existing --only-show-errors

kubectl apply -f - <<EOF
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: platform-critical
value: 1000000
globalDefault: false
description: "Platform-level components: Istio, cert-manager, Flux, ESO, Reloader"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: workload-high
value: 100000
globalDefault: false
description: "High-priority application workloads"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: workload-default
value: 10000
globalDefault: true
description: "Default priority for standard workloads"
EOF

echo "[priority-classes] ✓ PriorityClasses applied on ${CLUSTER}"
