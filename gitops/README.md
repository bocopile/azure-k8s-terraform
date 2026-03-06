# GitOps 레포 구조

Azure AKS 멀티클러스터 GitOps 매니페스트 저장소 양식입니다.
Flux v2 (`az k8s-configuration flux create`) 와 연동됩니다.

## 디렉토리 구조

```
gitops/
  clusters/
    mgmt/           # FluxConfig GITOPS_PATH=gitops/clusters/mgmt
    app1/           # FluxConfig GITOPS_PATH=gitops/clusters/app1
    app2/           # FluxConfig GITOPS_PATH=gitops/clusters/app2
  infrastructure/
    base/           # 공통 리소스 (Namespace, PriorityClass 등)
    overlays/
      mgmt/         # mgmt 전용 패치/추가 리소스
      app1/         # app1 전용 패치/추가 리소스
      app2/         # app2 전용 패치/추가 리소스
```

## 동작 흐름

```
FluxConfig (az k8s-configuration flux create)
  └─ GitRepository (SSH Deploy Key로 이 레포 감시)
       └─ Kustomization (GITOPS_PATH 아래 kustomization.yaml 적용)
            └─ clusters/<cluster>/kustomization.yaml
                 └─ clusters/<cluster>/infrastructure.yaml  ← Flux Kustomization CRD
                      └─ infrastructure/overlays/<cluster>/kustomization.yaml
                           └─ infrastructure/base/ (공통 리소스)
                           └─ <cluster 전용 리소스>
```

## 초기 설정

### 1. SSH Deploy Key 생성

```bash
ssh-keygen -t ed25519 -C flux-deploy -f ~/.ssh/flux-deploy-key -N ''
# 공개키를 GitHub/GitLab Deploy Key로 등록 (Read 권한만 필요)
cat ~/.ssh/flux-deploy-key.pub
```

### 2. terraform.tfvars 설정

```hcl
addon_repo_url       = "https://github.com/your-org/azure-k8s-terraform.git"
flux_ssh_private_key = file("~/.ssh/flux-deploy-key")

addon_env = {
  GITOPS_REPO_URL = "ssh://git@github.com/your-org/azure-k8s-terraform.git"
  GITOPS_BRANCH   = "main"
  GITOPS_PATH     = "gitops/clusters"   # clusters/<cluster>를 GITOPS_PATH/<cluster>로 참조
}
```

### 3. GITOPS_PATH 주의사항

`06-flux.sh`에서 `GITOPS_PATH`는 `clusters/${CLUSTER}` 형식으로 확장됩니다.
`GITOPS_PATH=gitops/clusters`로 설정하면 자동으로 `gitops/clusters/mgmt`, `gitops/clusters/app1` 등을 사용합니다.

## 클러스터별 리소스 추가 방법

1. `infrastructure/overlays/<cluster>/kustomization.yaml`에 리소스 파일 경로 추가
2. 해당 디렉토리에 YAML 파일 작성
3. 커밋 후 자동 동기화 (기본 5분 간격)

## Flux 동기화 상태 확인

```bash
# 동기화 상태 확인
kubectl get kustomization -n flux-system

# 이벤트 확인
kubectl describe kustomization infrastructure-mgmt -n flux-system

# 강제 재동기화
flux reconcile kustomization infrastructure-mgmt --with-source
```
