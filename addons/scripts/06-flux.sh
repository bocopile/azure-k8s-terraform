#!/usr/bin/env bash
# ============================================================
# 06-flux.sh — Enable AKS GitOps Add-on (Flux v2) + FluxConfig
#
# Authentication: SSH Deploy Key (K8s Secret)
# ADR-012 / C12: Federated Token not used
#
# 필수 환경변수:
#   GITOPS_REPO_URL      : GitOps 레포 SSH URL (예: ssh://git@github.com/org/repo.git)
#   GITOPS_BRANCH        : 동기화 브랜치 (기본: main)
#   GITOPS_PATH          : 레포 내 매니페스트 경로 (기본: clusters/<cluster>)
#   GITOPS_SSH_KEY_FILE  : SSH Deploy Key 파일 경로 (기본: ~/.ssh/flux-deploy-key)
#
# Usage: ./06-flux.sh <cluster-name>
# ============================================================
set -euo pipefail
CLUSTER="${1:?cluster name required}"

: "${GITOPS_REPO_URL:?GITOPS_REPO_URL 환경변수를 설정하세요 (예: ssh://git@github.com/org/repo.git)}"

GITOPS_BRANCH="${GITOPS_BRANCH:-main}"
GITOPS_PATH="${GITOPS_PATH:-clusters/${CLUSTER}}"
GITOPS_SSH_KEY_FILE="${GITOPS_SSH_KEY_FILE:-${HOME}/.ssh/flux-deploy-key}"

echo "[flux] Enabling AKS GitOps (Flux v2) on: ${CLUSTER}"

RG="rg-${PREFIX:-k8s}-${CLUSTER}"
CLUSTER_NAME="aks-${CLUSTER}"

# ---- 1. GitOps Extension 설치 ----
# 이미 설치된 경우 az k8s-extension create는 오류를 반환하므로 || true 처리
az k8s-extension create \
  --resource-group "${RG}" \
  --cluster-name "${CLUSTER_NAME}" \
  --cluster-type managedClusters \
  --extension-type Microsoft.Flux \
  --name flux \
  --scope cluster \
  --auto-upgrade-minor-version true 2>/dev/null || \
az k8s-extension show \
  --resource-group "${RG}" \
  --cluster-name "${CLUSTER_NAME}" \
  --cluster-type managedClusters \
  --name flux --query name -o tsv > /dev/null

echo "[flux] ✓ Flux v2 extension ready on ${CLUSTER}"

# ---- 2. SSH Deploy Key 검증 ----
if [[ ! -f "${GITOPS_SSH_KEY_FILE}" ]]; then
  echo "[flux] ERROR: SSH Deploy Key 파일을 찾을 수 없습니다: ${GITOPS_SSH_KEY_FILE}"
  echo "[flux] 생성 방법: ssh-keygen -t ed25519 -C flux-deploy -f ~/.ssh/flux-deploy-key -N ''"
  echo "[flux] 공개키(${GITOPS_SSH_KEY_FILE}.pub)를 GitHub/GitLab Deploy Key로 등록하세요."
  exit 1
fi

# ---- 3. FluxConfig 생성 ----
echo "[flux] Creating FluxConfig: gitops-${CLUSTER}"
echo "[flux]   repo:   ${GITOPS_REPO_URL}"
echo "[flux]   branch: ${GITOPS_BRANCH}"
echo "[flux]   path:   ${GITOPS_PATH}"

az k8s-configuration flux create \
  --resource-group "${RG}" \
  --cluster-name "${CLUSTER_NAME}" \
  --cluster-type managedClusters \
  --name "gitops-${CLUSTER}" \
  --namespace flux-system \
  --scope cluster \
  --url "${GITOPS_REPO_URL}" \
  --branch "${GITOPS_BRANCH}" \
  --ssh-private-key-file "${GITOPS_SSH_KEY_FILE}" \
  --kustomization \
    name=infra \
    path="${GITOPS_PATH}" \
    prune=true \
    sync_interval=5m

echo "[flux] ✓ FluxConfig 'gitops-${CLUSTER}' created — GitOps sync active"
