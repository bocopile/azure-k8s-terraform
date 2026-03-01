# ============================================================
# modules/aks/diagnostics.tf
# AKS Control Plane Diagnostic Settings → Log Analytics
#
# 수집 로그 카테고리 (Azure 권장 전량):
#   - kube-apiserver        : API 서버 요청/응답 로그
#   - kube-audit-admin      : 관리자 감사 로그 (읽기 제외, 볼륨 절감)
#     ※ kube-audit(전체)는 읽기 포함 → 볼륨/비용 3~5배 증가. 필요 시 교체
#   - kube-controller-manager: 컨트롤러 매니저 로그
#   - kube-scheduler        : 스케줄러 결정 로그
#   - cluster-autoscaler    : Cluster Autoscaler / Karpenter NAP 로그
#   - guard                 : Azure AD 인증 Guard 로그
#   - cloud-controller-manager: Azure Cloud Controller 로그
# ============================================================

resource "azurerm_monitor_diagnostic_setting" "aks" {
  for_each = var.clusters

  name                       = "diag-aks-${each.key}"
  target_resource_id         = azurerm_kubernetes_cluster.aks[each.key].id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  # Control Plane 로그 — 보안·운영 필수 카테고리
  enabled_log { category = "kube-apiserver" }
  enabled_log { category = "kube-audit-admin" } # kube-audit(전체)의 경량 버전: 읽기 제외, 쓰기/관리 작업만 수집 (비용 절감)
  enabled_log { category = "kube-controller-manager" }
  enabled_log { category = "kube-scheduler" }
  enabled_log { category = "cluster-autoscaler" }
  enabled_log { category = "guard" }
  enabled_log { category = "cloud-controller-manager" }

  # 메트릭
  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
