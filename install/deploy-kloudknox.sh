#!/usr/bin/env bash
###############################################################################
# deploy-kloudknox.sh — KloudKnox 배포
#
# 사용법:
#   bash deploy-kloudknox.sh install    # CRD + Operator + DaemonSet 배포
#   bash deploy-kloudknox.sh status     # 상태 확인
#   bash deploy-kloudknox.sh uninstall  # 전체 제거
###############################################################################
set -euo pipefail

KLOUDKNOX_DIR="/home/boan/KloudKnox"

log()  { echo -e "\e[1;32m[kloudknox]\e[0m $*"; }
warn() { echo -e "\e[1;33m[kloudknox]\e[0m $*"; }

do_install() {
    log "KloudKnox CRD 배포"
    kubectl apply -f "${KLOUDKNOX_DIR}/deployments/kloudknoxpolicy.yaml"

    log "KloudKnox Operator + Agent 배포"
    kubectl apply -f "${KLOUDKNOX_DIR}/deployments/kloudknox.yaml"

    log "Operator 대기..."
    kubectl -n kloudknox rollout status deployment/kloudknox-operator --timeout=120s

    log "Agent DaemonSet 대기..."
    kubectl -n kloudknox rollout status daemonset/kloudknox --timeout=120s

    log "배포 완료"
    do_status
}

do_status() {
    log "KloudKnox Pod 상태:"
    kubectl -n kloudknox get pods -o wide 2>/dev/null || warn "kloudknox 네임스페이스 없음"
    echo ""
    log "KloudKnoxPolicy CRD:"
    kubectl get crd kloudknoxpolicies.security.boanlab.com 2>/dev/null || warn "CRD 없음"
    echo ""
    log "적용된 정책:"
    kubectl get kloudknoxpolicies -A 2>/dev/null || warn "정책 없음"
}

do_uninstall() {
    log "KloudKnox 제거"
    kubectl delete -f "${KLOUDKNOX_DIR}/deployments/kloudknox.yaml" --ignore-not-found
    kubectl delete -f "${KLOUDKNOX_DIR}/deployments/kloudknoxpolicy.yaml" --ignore-not-found
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
