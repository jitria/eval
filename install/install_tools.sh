#!/usr/bin/env bash
###############################################################################
# install_tools.sh — kubectl 기반 벤치마크 도구 설치
#
# privileged DaemonSet을 배포하여 양쪽 노드에 lmbench, wrk2를 자동 빌드/설치
# SSH 접속 불필요. kubectl 접근 가능한 곳에서 실행.
#
# 사용법:
#   bash install_tools.sh install   # 설치 시작
#   bash install_tools.sh status    # 설치 진행 상태 확인
#   bash install_tools.sh cleanup   # 설치 Pod 정리
#
# 설치 경로 (각 노드의 호스트):
#   바이너리: /opt/bench-tools/bin/
#   소스:     /opt/bench-tools/src/
#   결과:     /tmp/2026SoCC/
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NS="bench-install"

log()  { echo -e "\e[1;32m[install]\e[0m $*"; }
warn() { echo -e "\e[1;33m[install]\e[0m $*"; }

do_install() {
    log "설치 DaemonSet 배포"
    kubectl apply -f "${SCRIPT_DIR}/00-namespace.yaml"
    kubectl apply -f "${SCRIPT_DIR}/01-install-daemonset.yaml"

    log "Pod 시작 대기..."
    kubectl -n "${NS}" rollout status daemonset/bench-installer --timeout=60s

    log "설치 진행 중... (lmbench + wrk2 소스 빌드, 수 분 소요)"
    log "진행 상태 확인: bash $0 status"
    echo ""

    # 로그 실시간 추적 (첫 번째 Pod)
    local pods
    pods=$(kubectl -n "${NS}" get pods -l app=bench-installer -o jsonpath='{.items[*].metadata.name}')

    for pod in ${pods}; do
        local node
        node=$(kubectl -n "${NS}" get pod "${pod}" -o jsonpath='{.spec.nodeName}')
        log "===== ${node} (${pod}) ====="
        log "로그 추적 시작... (빌드 완료 시 '설치 완료' 메시지 표시)"
        # 빌드 완료까지 대기 (최대 10분)
        kubectl -n "${NS}" logs -f "${pod}" --timeout=600s 2>/dev/null &
        LOG_PIDS+=($!)
    done

    # 모든 Pod에서 "설치 완료" 대기
    local all_done=false
    local waited=0
    while [[ "${all_done}" == "false" && ${waited} -lt 600 ]]; do
        sleep 10
        waited=$((waited + 10))
        all_done=true
        for pod in ${pods}; do
            if ! kubectl -n "${NS}" logs "${pod}" 2>/dev/null | grep -q "설치 완료"; then
                all_done=false
                break
            fi
        done
    done

    # 백그라운드 로그 종료
    for pid in "${LOG_PIDS[@]:-}"; do
        kill "${pid}" 2>/dev/null || true
    done

    if [[ "${all_done}" == "true" ]]; then
        echo ""
        log "===== 모든 노드 설치 완료 ====="
        do_status
    else
        warn "타임아웃. 상태 확인: bash $0 status"
    fi
}

do_status() {
    log "설치 Pod 상태:"
    kubectl -n "${NS}" get pods -o wide 2>/dev/null || { warn "bench-install 네임스페이스 없음"; return; }
    echo ""

    local pods
    pods=$(kubectl -n "${NS}" get pods -l app=bench-installer -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

    for pod in ${pods}; do
        local node
        node=$(kubectl -n "${NS}" get pod "${pod}" -o jsonpath='{.spec.nodeName}')
        echo ""
        log "── ${node} (${pod}) ──"

        # 바이너리 확인
        kubectl -n "${NS}" exec "${pod}" -- ls -la /opt/bench-tools/bin/ 2>/dev/null || warn "바이너리 확인 불가"

        # 결과 디렉토리 확인
        kubectl -n "${NS}" exec "${pod}" -- ls -d /tmp/2026SoCC/bench-5.* 2>/dev/null || warn "결과 디렉토리 없음"

        # 마지막 로그 5줄
        echo "  최근 로그:"
        kubectl -n "${NS}" logs "${pod}" --tail=5 2>/dev/null | sed 's/^/    /'
    done
}

do_cleanup() {
    log "설치 Pod 정리"
    kubectl delete namespace "${NS}" --ignore-not-found --grace-period=5
    log "정리 완료 (설치된 바이너리와 결과 디렉토리는 호스트에 유지됨)"
}

LOG_PIDS=()

case "${1:-help}" in
    install) do_install ;;
    status)  do_status ;;
    cleanup) do_cleanup ;;
    *)
        echo "사용법:"
        echo "  bash $0 install   # 양쪽 노드에 도구 설치"
        echo "  bash $0 status    # 설치 상태 확인"
        echo "  bash $0 cleanup   # 설치 Pod 정리"
        ;;
esac
