#!/usr/bin/env bash
###############################################################################
# deploy-falco.sh — Falco 배포 (Helm 기반, modern eBPF driver)
#
# 사용법:
#   bash deploy-falco.sh install              # 기본 설치
#   bash deploy-falco.sh install-with-rules <rules.yaml>  # 커스텀 룰 포함 설치
#   bash deploy-falco.sh load-rules <rules.yaml>          # 룰 핫 리로드
#   bash deploy-falco.sh status               # 상태 확인
#   bash deploy-falco.sh uninstall            # 전체 제거
###############################################################################
set -euo pipefail

NS="falco"

log()  { echo -e "\e[1;32m[falco]\e[0m $*"; }
warn() { echo -e "\e[1;33m[falco]\e[0m $*"; }

ensure_repo() {
    if ! helm repo list 2>/dev/null | grep -q falcosecurity; then
        log "Helm repo 추가"
        helm repo add falcosecurity https://falcosecurity.github.io/charts
    fi
    helm repo update
}

do_install() {
    ensure_repo

    log "Falco 설치 (modern_ebpf driver)"
    helm install falco falcosecurity/falco \
        --namespace "${NS}" --create-namespace \
        --set driver.kind=modern_ebpf \
        --set tty=true \
        --set falcoctl.artifact.install.enabled=true \
        --set falcoctl.artifact.follow.enabled=true \
        --wait --timeout=300s

    log "DaemonSet 대기..."
    kubectl -n "${NS}" rollout status daemonset/falco --timeout=300s

    log "설치 완료"
    do_status
}

do_install_with_rules() {
    local rules_file="${1:?룰 파일 경로 필요}"
    ensure_repo

    log "Falco 설치 (커스텀 룰 포함)"
    helm install falco falcosecurity/falco \
        --namespace "${NS}" --create-namespace \
        --set driver.kind=modern_ebpf \
        --set tty=true \
        --set falcoctl.artifact.install.enabled=true \
        --set falcoctl.artifact.follow.enabled=true \
        --set-file "customRules.bench-rules\\.yaml=${rules_file}" \
        --wait --timeout=300s

    kubectl -n "${NS}" rollout status daemonset/falco --timeout=300s
    log "설치 완료 (커스텀 룰 적용됨)"
    do_status
}

do_load_rules() {
    local rules_file="${1:?룰 파일 경로 필요}"

    log "커스텀 룰 ConfigMap 업데이트"
    kubectl -n "${NS}" create configmap falco-bench-rules \
        --from-file="bench-rules.yaml=${rules_file}" \
        --dry-run=client -o yaml | kubectl apply -f -

    log "Falco Helm 업그레이드 (룰 적용)"
    helm upgrade falco falcosecurity/falco \
        --namespace "${NS}" \
        --reuse-values \
        --set-file "customRules.bench-rules\\.yaml=${rules_file}" \
        --wait --timeout=120s

    log "룰 리로드 완료"
}

do_status() {
    log "Falco Pod 상태:"
    kubectl -n "${NS}" get pods -o wide 2>/dev/null || warn "falco 네임스페이스 없음"
    echo ""
    log "최근 로그 (5줄):"
    local pod
    pod=$(kubectl -n "${NS}" get pods -l app.kubernetes.io/name=falco -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "${pod}" ]]; then
        kubectl -n "${NS}" logs "${pod}" --tail=5 2>/dev/null || true
    fi
}

do_uninstall() {
    log "Falco 제거"
    helm uninstall falco --namespace "${NS}" 2>/dev/null || true
    kubectl delete namespace "${NS}" --ignore-not-found --grace-period=5
    log "제거 완료"
}

case "${1:-help}" in
    install)            do_install ;;
    install-with-rules) do_install_with_rules "${2:-}" ;;
    load-rules)         do_load_rules "${2:-}" ;;
    status)             do_status ;;
    uninstall)          do_uninstall ;;
    *)
        echo "사용법:"
        echo "  bash $0 install                        # 기본 설치"
        echo "  bash $0 install-with-rules <rules.yaml> # 커스텀 룰 포함 설치"
        echo "  bash $0 load-rules <rules.yaml>         # 룰 핫 리로드"
        echo "  bash $0 status                          # 상태 확인"
        echo "  bash $0 uninstall                       # 전체 제거"
        ;;
esac
