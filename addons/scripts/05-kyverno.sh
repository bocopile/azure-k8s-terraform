#!/usr/bin/env bash
# ============================================================
# 05-kyverno.sh — Install Kyverno (app clusters only)
#
# HA 설정:
#   - admissionController: 3 replicas (HPA min), PDB minAvailable 2
#   - background/cleanup/reports: 2 replicas each
#   - resources, TopologySpread, PriorityClass
#   - HPA: admission min 3 / max 5 / CPU 70%
#
# Usage: ./05-kyverno.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

if [[ "${CLUSTER}" == "mgmt" ]]; then
  echo "[kyverno] Skipping mgmt cluster (ADR-003: Kyverno is app-only)"
  exit 0
fi

echo "[kyverno] Installing Kyverno on: ${CLUSTER}"

KYVERNO_CHART_VERSION="3.7.1"
NAMESPACE="kyverno"

az aks get-credentials --resource-group "rg-k8s-demo-${CLUSTER}" \
  --name "aks-${CLUSTER}" --overwrite-existing --only-show-errors

helm repo add kyverno https://kyverno.github.io/kyverno --force-update
helm upgrade --install kyverno kyverno/kyverno \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${KYVERNO_CHART_VERSION}" \
  --set admissionController.replicas=3 \
  --set admissionController.container.resources.requests.cpu=100m \
  --set admissionController.container.resources.requests.memory=128Mi \
  --set admissionController.container.resources.limits.cpu=500m \
  --set admissionController.container.resources.limits.memory=256Mi \
  --set admissionController.priorityClassName=platform-critical \
  --set 'admissionController.topologySpreadConstraints[0].maxSkew=1' \
  --set 'admissionController.topologySpreadConstraints[0].topologyKey=topology.kubernetes.io/zone' \
  --set 'admissionController.topologySpreadConstraints[0].whenUnsatisfiable=ScheduleAnyway' \
  --set 'admissionController.topologySpreadConstraints[0].labelSelector.matchLabels.app\.kubernetes\.io/component=admission-controller' \
  --set backgroundController.replicas=2 \
  --set backgroundController.resources.requests.cpu=50m \
  --set backgroundController.resources.requests.memory=64Mi \
  --set backgroundController.resources.limits.cpu=200m \
  --set backgroundController.resources.limits.memory=128Mi \
  --set cleanupController.replicas=2 \
  --set cleanupController.resources.requests.cpu=50m \
  --set cleanupController.resources.requests.memory=64Mi \
  --set cleanupController.resources.limits.cpu=200m \
  --set cleanupController.resources.limits.memory=128Mi \
  --set reportsController.replicas=2 \
  --set reportsController.resources.requests.cpu=50m \
  --set reportsController.resources.requests.memory=64Mi \
  --set reportsController.resources.limits.cpu=200m \
  --set reportsController.resources.limits.memory=128Mi \
  --wait

# PDB — admission controller (가장 중요: webhook 가용성)
cat <<EOF | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: kyverno-admission-controller
  namespace: ${NAMESPACE}
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/component: admission-controller
EOF

# HPA — admission controller
cat <<EOF | kubectl apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: kyverno-admission-controller
  namespace: ${NAMESPACE}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: kyverno-admission-controller
  minReplicas: 3
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
EOF

# ============================================================
# Kyverno ClusterPolicies — PDB + TopologySpread 강제
# ============================================================

# Policy 1: replicas > 1인 Deployment에 PDB 자동 생성 (generate)
cat <<'POLICY' | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: generate-pdb
  annotations:
    policies.kyverno.io/title: Auto-generate PodDisruptionBudget
    policies.kyverno.io/description: >-
      replicas > 1인 Deployment에 대응하는 PDB를 자동 생성합니다.
      노드 업그레이드/drain 시 최소 가용성 보장.
spec:
  rules:
    - name: create-pdb
      match:
        any:
          - resources:
              kinds:
                - Deployment
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kube-node-lease
                - gatekeeper-system
                - kyverno
      preconditions:
        all:
          - key: "{{ request.object.spec.replicas || '1' }}"
            operator: GreaterThan
            value: "1"
      generate:
        apiVersion: policy/v1
        kind: PodDisruptionBudget
        name: "{{ request.object.metadata.name }}-pdb"
        namespace: "{{ request.object.metadata.namespace }}"
        synchronize: true
        data:
          spec:
            minAvailable: 1
            selector:
              matchLabels:
                "{{ request.object.spec.selector.matchLabels }}"
POLICY

# Policy 2: replicas > 1인 Deployment에 TopologySpreadConstraints 강제
cat <<'POLICY' | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-topology-spread
  annotations:
    policies.kyverno.io/title: Require TopologySpreadConstraints
    policies.kyverno.io/description: >-
      replicas > 1인 Deployment는 topologySpreadConstraints를
      반드시 포함해야 합니다. Zone 분산으로 가용성 보장.
spec:
  validationFailureAction: Audit
  background: true
  rules:
    - name: check-topology-spread
      match:
        any:
          - resources:
              kinds:
                - Deployment
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kube-node-lease
                - gatekeeper-system
      preconditions:
        all:
          - key: "{{ request.object.spec.replicas || '1' }}"
            operator: GreaterThan
            value: "1"
      validate:
        message: >-
          replicas > 1인 Deployment '{{ request.object.metadata.name }}'에
          topologySpreadConstraints가 필요합니다.
          Zone 분산을 위해 topology.kubernetes.io/zone 키를 사용하세요.
        pattern:
          spec:
            template:
              spec:
                topologySpreadConstraints:
                  - topologyKey: "topology.kubernetes.io/zone"
POLICY

echo "[kyverno] ✓ ClusterPolicies applied: generate-pdb, require-topology-spread"
echo "[kyverno] NOTE: require-topology-spread Audit → Enforce 전환: validationFailureAction: Enforce"
echo "[kyverno] ✓ Installed chart v${KYVERNO_CHART_VERSION} on ${CLUSTER} (HA + HPA + Policies)"
