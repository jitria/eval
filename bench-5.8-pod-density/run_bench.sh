#!/usr/bin/env bash
###############################################################################
# run_bench.sh — 5.8 Pod Density (v2)
#
# 개선 (v1 → v2):
#   1) 차분 기반 CPU 측정 (cumulative /proc/stat → differential)
#   2) 다중 trial + cross-trial avg/stddev
#   3) Pod 수를 모니터에 인자로 전달 (ps grep 제거)
#   4) kubectl cp + cat fallback 결과 수집
#   5) 파일명 타임스탬프 제거 (label/trial/step 기반)
#   6) trial 간 캐시 초기화 (drop_caches + sync)
#   7) Per-trial + cross-trial 통계 CSV
#
# 아키텍처:
#   compute-node-2
#   ├── resource-monitor DaemonSet (privileged, hostPID)
#   │   └── 차분 /proc/stat + /proc/<pid>/stat
#   ├── density-pod-0..N (busybox, 최소 워크로드)
#   └── (KloudKnox agent, if applicable)
#
# 사용법:
#   bash run_bench.sh run   [vanilla|kloudknox|falco|tetragon] [agent_process_name]
#   bash run_bench.sh deploy
#   bash run_bench.sh cleanup
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NS="bench-density"
RESULT_HOST="/tmp/2026SoCC/bench-5.8"
LABEL="${2:-vanilla}"
AGENT_NAME="${3:-}"

# 에이전트 프로세스명 자동 매핑 (명시적 지정이 없을 때)
if [[ -z "${AGENT_NAME}" ]]; then
    case "${LABEL}" in
        kloudknox) AGENT_NAME="kloudknox" ;;
        falco)     AGENT_NAME="falco" ;;
        tetragon)  AGENT_NAME="tetragon" ;;
    esac
fi

POD_STEPS="${POD_STEPS:-1 10 20 30 50 70 100 110}"
TRIALS="${TRIALS:-3}"
STABILIZE_WAIT="${STABILIZE_WAIT:-30}"
MEASURE_DURATION="${MEASURE_DURATION:-60}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-5}"
POD_READY_TIMEOUT="${POD_READY_TIMEOUT:-300}"

log()  { echo -e "\e[1;36m[5.8]\e[0m $*"; }
warn() { echo -e "\e[1;33m[5.8]\e[0m $*"; }

MONITOR_POD=""

get_monitor_pod() {
    kubectl -n "${NS}" get pods -l app=resource-monitor \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

mon_exec() { kubectl -n "${NS}" exec "${MONITOR_POD}" -- bash -c "$1" 2>&1; }

# ── 정책 적용 검증 ─────────────────────────────────────────────────
verify_policy() {
    [[ "${LABEL}" == "vanilla" ]] && return
    log "정책 적용 검증 (${LABEL})"
    local ok=false
    case "${LABEL}" in
        kloudknox)
            for _i in $(seq 1 15); do
                if kubectl -n "${NS}" get kloudknoxpolicy.security.boanlab.com -o name 2>/dev/null | grep -q .; then
                    ok=true; break
                fi
                sleep 1
            done
            if [[ "${ok}" == "true" ]]; then
                kubectl logs -n kloudknox -l boanlab.com/app=kloudknox --tail=10 2>/dev/null \
                    | grep -qi "KloudKnoxPolicy" \
                    && log "  KloudKnox 에이전트 정책 로드 확인" \
                    || warn "  KloudKnox 에이전트 로그 확인 불가 (리소스는 존재)"
            else
                warn "KloudKnox 정책 리소스 미생성"; return 1
            fi
            ;;
        falco)
            for _i in $(seq 1 15); do
                if kubectl logs -n falco -l app.kubernetes.io/name=falco -c falco --tail=30 2>/dev/null \
                    | grep -qi "Loading rules\|Loaded event"; then
                    ok=true; break
                fi
                sleep 1
            done
            [[ "${ok}" == "true" ]] && log "  Falco 룰 로딩 확인" \
                || { warn "Falco 룰 로딩 미확인"; return 1; }
            ;;
        tetragon)
            for _i in $(seq 1 15); do
                if kubectl get tracingpolicy -o name 2>/dev/null | grep -q .; then
                    ok=true; break
                fi
                sleep 1
            done
            if [[ "${ok}" == "true" ]]; then
                if kubectl logs -n kube-system -l app.kubernetes.io/name=tetragon \
                    -c tetragon --tail=30 2>/dev/null | grep -qi "Loaded sensor successfully"; then
                    log "  TracingPolicy 센서 로드 확인"
                else
                    warn "  TracingPolicy 센서 로드 로그 미확인 (리소스는 존재)"
                fi
            else
                warn "TracingPolicy 리소스 미생성"; return 1
            fi
            ;;
    esac
    log "정책 검증 완료"
}

# ── 정책 적용/제거 ─────────────────────────────────────────────────
apply_policy() {
    [[ "${LABEL}" == "vanilla" ]] && return
    log "정책 적용 (${LABEL})"
    case "${LABEL}" in
        kloudknox)
            kubectl apply -f "${SCRIPT_DIR}/policies/kloudknox-policy.yaml"
            ;;
        falco)
            helm upgrade falco falcosecurity/falco -n falco --reuse-values \
                --set-file "customRules.bench-rules\.yaml=${SCRIPT_DIR}/policies/falco-rules.yaml" \
                --wait --timeout 120s
            ;;
        tetragon)
            kubectl apply -f "${SCRIPT_DIR}/policies/tetragon-policy.yaml"
            ;;
    esac
    verify_policy
    log "정책 적용 완료"
}

remove_policy() {
    [[ "${LABEL}" == "vanilla" ]] && return
    log "정책 제거 (${LABEL})"
    case "${LABEL}" in
        kloudknox)
            kubectl delete -f "${SCRIPT_DIR}/policies/kloudknox-policy.yaml" --ignore-not-found 2>/dev/null || true
            ;;
        falco)
            helm upgrade falco falcosecurity/falco -n falco --reuse-values \
                --set "customRules.bench-rules\\.yaml=" \
                --wait --timeout 120s 2>/dev/null || true
            ;;
        tetragon)
            kubectl delete -f "${SCRIPT_DIR}/policies/tetragon-policy.yaml" --ignore-not-found 2>/dev/null || true
            ;;
    esac
    log "정책 제거 완료"
}

# ── deploy ───────────────────────────────────────────────────────────
do_deploy() {
    log "배포 시작"
    kubectl apply -f "${SCRIPT_DIR}/00-namespace.yaml"
    kubectl apply -f "${SCRIPT_DIR}/01-monitor-daemonset.yaml"

    log "모니터링 DaemonSet 대기..."
    kubectl -n "${NS}" rollout status daemonset/resource-monitor --timeout=120s

    MONITOR_POD=$(get_monitor_pod)
    log "모니터링 Pod: ${MONITOR_POD}"

    # procps 설치 (pgrep, nproc 등)
    mon_exec 'apt-get update -qq && apt-get install -y -qq procps >/dev/null 2>&1' || true

    log "배포 완료"
    kubectl -n "${NS}" get pods -o wide
}

# ── density Pod 배포 (additive) ──────────────────────────────────────
deploy_density_pods() {
    local target="$1"
    local current
    current=$(kubectl -n "${NS}" get pods -l app=density-bench --no-headers 2>/dev/null | wc -l || echo 0)

    if [[ ${current} -ge ${target} ]]; then
        log "  이미 ${current}개 Pod (목표: ${target})"
        return
    fi

    local to_add=$((target - current))
    local manifests="/tmp/density_pods_${target}.yaml"
    > "${manifests}"
    for ((i = current; i < target; i++)); do
        sed "s/__INDEX__/${i}/g" "${SCRIPT_DIR}/pod-template.yaml" >> "${manifests}"
        echo "---" >> "${manifests}"
    done

    log "  ${to_add}개 Pod 추가 (${current} → ${target})"
    kubectl apply -f "${manifests}"

    # Running 대기
    local ready=0 waited=0
    while [[ ${ready} -lt ${target} && ${waited} -lt ${POD_READY_TIMEOUT} ]]; do
        ready=$(kubectl -n "${NS}" get pods -l app=density-bench \
            --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo 0)
        printf "\r  Running: %d/%d (%ds)" "${ready}" "${target}" "${waited}"
        sleep 5
        waited=$((waited + 5))
    done
    echo ""

    if [[ ${ready} -lt ${target} ]]; then
        warn "  Pod 미완료: ${ready}/${target} Running (${POD_READY_TIMEOUT}s 타임아웃)"
    fi
}

# ── density Pod 삭제 ─────────────────────────────────────────────────
delete_density_pods() {
    log "밀도 Pod 삭제"
    kubectl -n "${NS}" delete pods -l app=density-bench --grace-period=0 --force 2>/dev/null || true

    local remaining=1 waited=0
    while [[ ${remaining} -gt 0 && ${waited} -lt 120 ]]; do
        remaining=$(kubectl -n "${NS}" get pods -l app=density-bench --no-headers 2>/dev/null | wc -l || echo 0)
        [[ ${remaining} -eq 0 ]] && break
        sleep 3
        waited=$((waited + 3))
    done
    log "  삭제 완료"
}

# ── trial 간 캐시 초기화 ─────────────────────────────────────────────
flush_caches() {
    log "캐시 초기화 (sync + drop_caches)"
    mon_exec 'sync && echo 3 > /proc/sys/vm/drop_caches' || true
    sleep 3
}

# ── per-step 통계 (샘플 CSV → avg/stddev) ────────────────────────────
compute_step_stats() {
    local csv="$1"
    # 입력: timestamp,pod_count,agent_cpu,agent_mem,node_cpu,node_mem_used,node_mem_total
    # 출력: avg_ac,std_ac,avg_am,std_am,avg_nc,std_nc,avg_nm,std_nm,samples
    awk -F',' '
    NR > 1 {
        n++
        ac=$3; am=$4; nc=$5; nm=$6
        sac+=ac; sam+=am; snc+=nc; snm+=nm
        sac2+=ac*ac; sam2+=am*am; snc2+=nc*nc; snm2+=nm*nm
    }
    END {
        if (n == 0) { printf "0,0,0,0,0,0,0,0,0\n"; exit }
        aac=sac/n; aam=sam/n; anc=snc/n; anm=snm/n
        vac=(sac2/n)-(aac*aac); dac=sqrt(vac>0?vac:0)
        vam=(sam2/n)-(aam*aam); dam=sqrt(vam>0?vam:0)
        vnc=(snc2/n)-(anc*anc); dnc=sqrt(vnc>0?vnc:0)
        vnm=(snm2/n)-(anm*anm); dnm=sqrt(vnm>0?vnm:0)
        printf "%.2f,%.2f,%.1f,%.1f,%.1f,%.1f,%.0f,%.0f,%d\n",aac,dac,aam,dam,anc,dnc,anm,dnm,n
    }' "${csv}"
}

# ── run ──────────────────────────────────────────────────────────────
do_run() {
    do_deploy
    MONITOR_POD=$(get_monitor_pod)
    mkdir -p "${RESULT_HOST}"

    local num_samples=$((MEASURE_DURATION / SAMPLE_INTERVAL))

    # 정책 적용
    apply_policy

    # 시스템 정보
    mon_exec "{ uname -a; echo '---'; lscpu | head -20; echo '---'; free -h; } > /results/${LABEL}_sysinfo.txt"

    # ── Per-trial summary CSV ──
    local summary="${RESULT_HOST}/${LABEL}_summary.csv"
    echo "label,trial,pod_count,avg_agent_cpu,std_agent_cpu,avg_agent_mem,std_agent_mem,avg_node_cpu,std_node_cpu,avg_node_mem,std_node_mem,samples" > "${summary}"

    for trial in $(seq 1 "${TRIALS}"); do
        log "===== Trial ${trial}/${TRIALS} ====="

        # trial 시작 전: 밀도 Pod 삭제 + 캐시 초기화
        delete_density_pods
        flush_caches

        for pod_count in ${POD_STEPS}; do
            log "── pods=${pod_count} (trial ${trial}) ──"

            deploy_density_pods "${pod_count}"

            log "  안정화 대기 (${STABILIZE_WAIT}초)"
            sleep "${STABILIZE_WAIT}"

            # 모니터링 실행 (고정 샘플 수 후 자동 종료)
            local remote_csv="${LABEL}_t${trial}_pods${pod_count}.csv"
            log "  모니터링 (${num_samples} samples x ${SAMPLE_INTERVAL}s = ${MEASURE_DURATION}s)"

            mon_exec "bash /scripts/monitor_in_pod.sh ${pod_count} '${AGENT_NAME}' ${SAMPLE_INTERVAL} ${num_samples} ${remote_csv}" || true

            # 결과 수집 (kubectl cp → cat fallback)
            local local_csv="${RESULT_HOST}/${remote_csv}"
            kubectl cp "${NS}/${MONITOR_POD}:/results/${remote_csv}" "${local_csv}" 2>/dev/null || \
                mon_exec "cat /results/${remote_csv}" > "${local_csv}" 2>/dev/null || true

            # per-step 통계
            if [[ -f "${local_csv}" ]] && [[ $(wc -l < "${local_csv}") -gt 1 ]]; then
                local stats
                stats=$(compute_step_stats "${local_csv}")
                echo "${LABEL},${trial},${pod_count},${stats}" >> "${summary}"
                log "  결과: $(echo "${stats}" | awk -F',' '{printf "agent_cpu=%.2f±%.2f%% agent_mem=%.1f±%.1fMB node_cpu=%.1f±%.1f%% node_mem=%s±%sMB (n=%s)", $1,$2,$3,$4,$5,$6,$7,$8,$9}')"
            else
                warn "  결과 없음"
                echo "${LABEL},${trial},${pod_count},0,0,0,0,0,0,0,0,0" >> "${summary}"
            fi
        done
    done

    # 마지막 밀도 Pod 정리
    delete_density_pods

    # ── Cross-trial 통계 ──────────────────────────────────────────────
    log "===== Cross-trial 통계 ====="
    local cross_stats="${RESULT_HOST}/${LABEL}_cross_trial_stats.csv"
    echo "label,pod_count,trials,avg_agent_cpu,std_agent_cpu,avg_agent_mem,std_agent_mem,avg_node_cpu,std_node_cpu,avg_node_mem,std_node_mem" > "${cross_stats}"

    for pod_count in ${POD_STEPS}; do
        # summary CSV에서 해당 pod_count의 per-trial avg 추출 → cross-trial avg/stddev
        awk -F',' -v pc="${pod_count}" -v lab="${LABEL}" '
        NR > 1 && $3 == pc {
            n++
            ac[n]=$4; am[n]=$6; nc[n]=$8; nm[n]=$10
            sac+=$4; sam+=$6; snc+=$8; snm+=$10
            sac2+=$4*$4; sam2+=$6*$6; snc2+=$8*$8; snm2+=$10*$10
        }
        END {
            if (n == 0) { printf "%s,%s,0,0,0,0,0,0,0,0,0\n",lab,pc; exit }
            aac=sac/n; aam=sam/n; anc=snc/n; anm=snm/n
            vac=(sac2/n)-(aac*aac); dac=sqrt(vac>0?vac:0)
            vam=(sam2/n)-(aam*aam); dam=sqrt(vam>0?vam:0)
            vnc=(snc2/n)-(anc*anc); dnc=sqrt(vnc>0?vnc:0)
            vnm=(snm2/n)-(anm*anm); dnm=sqrt(vnm>0?vnm:0)
            printf "%s,%s,%d,%.2f,%.2f,%.1f,%.1f,%.1f,%.1f,%.0f,%.0f\n",lab,pc,n,aac,dac,aam,dam,anc,dnc,anm,dnm
        }' "${summary}" >> "${cross_stats}"
    done

    echo ""
    log "Per-trial 요약:"
    column -t -s',' "${summary}" 2>/dev/null || cat "${summary}"
    echo ""
    log "Cross-trial 통계:"
    column -t -s',' "${cross_stats}" 2>/dev/null || cat "${cross_stats}"
    echo ""
    log "결과: ${RESULT_HOST}/"
    log "완료 (label=${LABEL}, trials=${TRIALS}, steps=${POD_STEPS})"
    log "  stabilize=${STABILIZE_WAIT}s, measure=${MEASURE_DURATION}s, interval=${SAMPLE_INTERVAL}s"
}

# ── cleanup ──────────────────────────────────────────────────────────
do_cleanup() {
    log "전체 정리"
    remove_policy
    kubectl delete namespace "${NS}" --ignore-not-found --grace-period=5
    rm -f /tmp/density_pods_*.yaml
    log "정리 완료"
}

case "${1:-help}" in
    run)     do_run ;;
    deploy)  do_deploy ;;
    cleanup) do_cleanup ;;
    *)
        echo "사용법:"
        echo "  bash $0 run [vanilla|kloudknox|falco|tetragon] [agent_name]"
        echo "  bash $0 deploy"
        echo "  bash $0 cleanup"
        echo ""
        echo "환경변수:"
        echo "  TRIALS=3              반복 횟수 (기본 3)"
        echo "  POD_STEPS='1 10 ...'  Pod 수 단계 (기본: 1 10 20 30 50 70 100 110)"
        echo "  STABILIZE_WAIT=30     안정화 대기 (초)"
        echo "  MEASURE_DURATION=60   측정 시간 (초)"
        echo "  SAMPLE_INTERVAL=5     샘플링 간격 (초)"
        echo "  POD_READY_TIMEOUT=300 Pod Ready 대기 타임아웃 (초)"
        ;;
esac
