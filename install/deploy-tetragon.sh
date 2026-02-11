#!/usr/bin/env bash
###############################################################################
# deploy-tetragon.sh — Tetragon 배포 (Helm 기반)
#
# 사용법:
#   bash deploy-tetragon.sh install    # 설치
#   bash deploy-tetragon.sh status     # 상태 확인
#   bash deploy-tetragon.sh uninstall  # 전체 제거
###############################################################################
set -euo pipefail

NS="kube-system"

log()  { echo -e "\e[1;32m[tetragon]\e[0m $*"; }
warn() { echo -e "\e[1;33m[tetragon]\e[0m $*"; }

ensure_repo() {
    if ! helm repo list 2>/dev/null | grep -q cilium; then
        log "Helm repo 추가"
        helm repo add cilium https://helm.cilium.io
    fi
    helm repo update
}

do_install() {
    ensure_repo

    log "Tetragon 설치"
    helm install tetragon cilium/tetragon \
        --namespace "${NS}" \
        --wait --timeout=300s

    log "DaemonSet 대기..."
    kubectl -n "${NS}" rollout status daemonset/tetragon --timeout=300s

    # tetra CLI 설치
    log "tetra CLI 설치"
    curl -sL https://github.com/cilium/tetragon/releases/latest/download/tetra-linux-amd64.tar.gz | tar -xz
    sudo mv tetra /usr/local/bin/
    tetra version && log "tetra CLI 설치 완료" || warn "tetra CLI 설치 실패"

    log "설치 완료"
    do_status
}

do_status() {
    log "Tetragon Pod 상태:"
    kubectl -n "${NS}" get pods -l app.kubernetes.io/name=tetragon -o wide 2>/dev/null || warn "Tetragon Pod 없음"
    echo ""
    log "TracingPolicy 목록:"
    kubectl get tracingpolicies -A 2>/dev/null || warn "TracingPolicy CRD 없음"
}

do_uninstall() {
    log "TracingPolicy 전체 삭제"
    kubectl delete tracingpolicies --all 2>/dev/null || true
    log "Tetragon 제거"
    helm uninstall tetragon --namespace "${NS}" 2>/dev/null || true
    log "제거 완료"
}

case "${1:-help}" in
    install)   do_install ;;
    status)    do_status ;;
    uninstall) do_uninstall ;;
    *)
        echo "사용법: bash $0 {install|status|uninstall}"
        ;;
esac
