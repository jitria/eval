#!/usr/bin/env bash
###############################################################################
# run_bench.sh — 5.8 Agent Resource Overhead
#
# HTTP 부하(ab) 중 보안 에이전트 CPU/Memory 사용량 측정.
# bench-5.9의 Nginx+ab 인프라를 재사용하여 고정 concurrency(c=300)로
# 60초 동안 부하를 걸면서 에이전트 프로세스의 CPU%와 Memory(MB)를 샘플링.
#
# 아키텍처:
#   compute-node-2: Nginx + 에이전트 DaemonSet + Monitor DaemonSet
#   compute-node-1: ab-client Pod (ab -n 2000000 -c 300 -k)
#
# 사용법:
#   bash run_bench.sh run [vanilla|kloudknox|falco|tetragon]
#   bash run_bench.sh deploy
#   bash run_bench.sh cleanup
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH59_DIR="${SCRIPT_DIR}/../bench-5.9-nginx-ab"

NS="bench-nginx-ab"
NS_RESOURCE="bench-resource"
RESULT_HOST="/tmp/2026SoCC/bench-5.8"

MODE="${1:-help}"
LABEL="${2:-vanilla}"

# 에이전트 프로세스명 매핑
AGENT_NAME=""
case "${LABEL}" in
    kloudknox) AGENT_NAME="kloudknox" ;;
    falco)     AGENT_NAME="falco" ;;
    tetragon)  AGENT_NAME="tetragon" ;;
esac

# ── 환경변수 ──────────────────────────────────────────────────────────
TRIALS="${TRIALS:-3}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-5}"
NUM_SAMPLES="${NUM_SAMPLES:-12}"
AB_REQUESTS="${AB_REQUESTS:-2000000}"
AB_CONCURRENCY="${AB_CONCURRENCY:-300}"
WARMUP_REQUESTS="${WARMUP_REQUESTS:-1000}"
COOLDOWN="${COOLDOWN:-10}"

SERVER_URL="http://nginx-ab-svc.${NS}.svc.cluster.local:80/"
AB_POD="ab-client"

log()  { echo -e "\e[1;36m[5.8]\e[0m $*"; }
warn() { echo -e "\e[1;33m[5.8]\e[0m $*"; }

ab_exec()  { kubectl -n "${NS}" exec "${AB_POD}" -- bash -c "ulimit -n 65535; $1" 2>&1; }
mon_exec() { local p="$1"; shift; kubectl -n "${NS_RESOURCE}" exec "${p}" -- bash -c "$*" 2>&1; }

# ── 모니터 Pod 검색 ────────────────────────────────────────────────────
get_monitor_pod() {
    local node="$1"
    kubectl -n "${NS_RESOURCE}" get pods -l app=resource-monitor \
        --field-selector "spec.nodeName=${node}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# ── 정책 검증 ──────────────────────────────────────────────────────────
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
            local fpod=""
            for _i in $(seq 1 30); do
                fpod=$(kubectl -n falco get pods -l app.kubernetes.io/name=falco \
                    --field-selector=status.phase=Running \
                    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
                if [[ -n "${fpod}" ]] && \
                   kubectl -n falco exec "${fpod}" -c falco -- \
                       test -s /etc/falco/rules.d/bench-rules.yaml 2>/dev/null; then
                    ok=true; break
                fi
                sleep 2
            done
            [[ "${ok}" == "true" ]] && log "  Falco 커스텀 룰 마운트 확인 (${fpod})" \
                || { warn "Falco 룰 파일 미확인"; return 1; }
            ;;
        tetragon)
            for _i in $(seq 1 15); do
                if kubectl get tracingpolicy -o name 2>/dev/null | grep -q .; then
                    ok=true; break
                fi
                sleep 1
            done
            if [[ "${ok}" == "true" ]]; then
                sleep 3
                local tpod
                tpod=$(kubectl -n kube-system get pods -l app.kubernetes.io/name=tetragon \
                    --field-selector=status.phase=Running \
                    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
                if [[ -n "${tpod}" ]]; then
                    log "  tetra tracingpolicy list:"
                    kubectl -n kube-system exec "${tpod}" -c tetragon -- \
                        tetra tracingpolicy list 2>/dev/null | while IFS= read -r line; do
                        log "    ${line}"
                    done
                    if kubectl -n kube-system exec "${tpod}" -c tetragon -- \
                        tetra tracingpolicy list 2>/dev/null | grep -qi "error"; then
                        warn "  TracingPolicy error state 감지"; return 1
                    fi
                    log "  TracingPolicy 센서 로드 확인"
                else
                    warn "  Tetragon Pod 미발견 — 로그로 폴백"
                    kubectl logs -n kube-system -l app.kubernetes.io/name=tetragon \
                        -c tetragon --tail=30 2>/dev/null | grep -qi "Loaded sensor" \
                        && log "  센서 로드 로그 확인" \
                        || warn "  센서 로드 로그 미확인"
                fi
            else
                warn "TracingPolicy 리소스 미생성"; return 1
            fi
            ;;
    esac
    log "정책 검증 완료"
}

# ── 정책 적용/제거 ─────────────────────────────────────────────────────
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
            if helm status falco -n falco &>/dev/null; then
                helm upgrade falco falcosecurity/falco -n falco --reuse-values \
                    --set-json 'customRules={}' \
                    --wait --timeout 120s 2>/dev/null || true
            fi
            ;;
        tetragon)
            kubectl delete -f "${SCRIPT_DIR}/policies/tetragon-policy.yaml" --ignore-not-found 2>/dev/null || true
            ;;
    esac
    log "정책 제거 완료"
}

# ── per-trial 통계 (샘플 CSV → avg/stddev) ────────────────────────────
compute_sample_stats() {
    local csv="$1"
    # 입력: timestamp,agent_cpu_pct,agent_mem_mb,node_cpu_pct,node_mem_used_mb
    # 출력: avg_agent_cpu,std_agent_cpu,avg_agent_mem,std_agent_mem,samples
    awk -F',' '
    NR > 1 {
        n++
        ac=$2; am=$3
        sac+=ac; sam+=am
        sac2+=ac*ac; sam2+=am*am
    }
    END {
        if (n == 0) { printf "0,0,0,0,0\n"; exit }
        aac=sac/n; aam=sam/n
        vac=(sac2/n)-(aac*aac); dac=sqrt(vac>0?vac:0)
        vam=(sam2/n)-(aam*aam); dam=sqrt(vam>0?vam:0)
        printf "%.2f,%.2f,%.1f,%.1f,%d\n",aac,dac,aam,dam,n
    }' "${csv}"
}

# ── cross-trial 통계 ──────────────────────────────────────────────────
compute_resource_stats() {
    local summary_csv="$1" stats_csv="$2"

    echo "label,trials,avg_agent_cpu,std_agent_cpu,avg_agent_mem,std_agent_mem" > "${stats_csv}"

    # summary: label,trial,avg_agent_cpu,std_agent_cpu,avg_agent_mem,std_agent_mem,samples
    # cross-trial: avg/std of per-trial avg ($3,$5)
    awk -F',' -v lab="${LABEL}" '
    NR > 1 {
        n++
        sac+=$3; sam+=$5
        sac2+=$3*$3; sam2+=$5*$5
    }
    END {
        if (n == 0) { printf "%s,0,0,0,0,0\n",lab; exit }
        aac=sac/n; aam=sam/n
        vac=(sac2/n)-(aac*aac); dac=sqrt(vac>0?vac:0)
        vam=(sam2/n)-(aam*aam); dam=sqrt(vam>0?vam:0)
        printf "%s,%d,%.2f,%.2f,%.1f,%.1f\n",lab,n,aac,dac,aam,dam
    }' "${summary_csv}" >> "${stats_csv}"
}

# ═══════════════════════════════════════════════════════════════════════
# DEPLOY
# ═══════════════════════════════════════════════════════════════════════
do_deploy() {
    log "===== 인프라 배포 ====="

    # 1. bench-5.9 인프라 (nginx + ab-client)
    log "bench-5.9 인프라 배포 (nginx + ab-client)"
    kubectl apply -f "${BENCH59_DIR}/00-namespace.yaml"
    kubectl apply -f "${BENCH59_DIR}/nginx-configmap.yaml"
    kubectl apply -f "${BENCH59_DIR}/01-nginx-deployment.yaml"
    kubectl apply -f "${BENCH59_DIR}/02-ab-client-pod.yaml"

    kubectl -n "${NS}" rollout status deployment/nginx-ab --timeout=120s
    kubectl -n "${NS}" wait --for=condition=Ready pod/${AB_POD} --timeout=120s

    # ab 설치 확인
    log "ab 설치 확인..."
    if ! ab_exec 'which ab' &>/dev/null; then
        log "ab 설치 중 (apache2-utils)..."
        ab_exec 'apt-get update -qq && apt-get install -y -qq apache2-utils > /dev/null 2>&1'
    fi
    ab_exec 'ab -V | head -1'

    # 2. 모니터 DaemonSet
    log "모니터 DaemonSet 배포"
    kubectl apply -f "${SCRIPT_DIR}/00-namespace.yaml"
    kubectl apply -f "${SCRIPT_DIR}/01-monitor-daemonset.yaml"
    kubectl -n "${NS_RESOURCE}" rollout status daemonset/resource-monitor --timeout=120s

    kubectl -n "${NS}" get pods -o wide
    kubectl -n "${NS_RESOURCE}" get pods -o wide
    log "인프라 배포 완료"
}

# ═══════════════════════════════════════════════════════════════════════
# RUN
# ═══════════════════════════════════════════════════════════════════════
do_run() {
    log "===== Agent Resource Overhead (label=${LABEL}) ====="
    mkdir -p "${RESULT_HOST}"

    # 1. 인프라 배포
    do_deploy

    # 2. 정책 적용
    apply_policy

    # 3. 서버 연결 확인
    log "서버 연결 확인..."
    local connected=false
    for _i in $(seq 1 30); do
        if ab_exec "ab -n 1 -c 1 ${SERVER_URL}" &>/dev/null; then
            connected=true; break
        fi
        sleep 1
    done
    if [[ "${connected}" != "true" ]]; then
        warn "서버 연결 실패 (30초 타임아웃)"; return 1
    fi
    log "서버 연결 확인 완료"

    # 4. 워밍업
    log "워밍업 (${WARMUP_REQUESTS} requests, c=50)"
    ab_exec "ab -n ${WARMUP_REQUESTS} -c 50 -k ${SERVER_URL} > /dev/null 2>&1" || true
    sleep 3

    # 5. 모니터 Pod (compute-node-2)
    local mon_pod
    mon_pod=$(get_monitor_pod "compute-node-2")
    [[ -n "${mon_pod}" ]] || { warn "monitor pod not found on compute-node-2"; return 1; }
    log "Monitor Pod: ${mon_pod} (compute-node-2)"

    local summary="${RESULT_HOST}/${LABEL}_resource_summary.csv"
    echo "label,trial,avg_agent_cpu,std_agent_cpu,avg_agent_mem,std_agent_mem,samples" > "${summary}"

    # 6. Trial 루프
    for trial in $(seq 1 "${TRIALS}"); do
        log "===== Trial ${trial}/${TRIALS} ====="
        local csv_name="${LABEL}_resource_t${trial}.csv"

        # 모니터 시작 (백그라운드, NUM_SAMPLES x SAMPLE_INTERVAL = 60s)
        log "  모니터 시작 (${NUM_SAMPLES} x ${SAMPLE_INTERVAL}s = $(( NUM_SAMPLES * SAMPLE_INTERVAL ))s)"
        mon_exec "${mon_pod}" "bash /scripts/monitor_in_pod.sh '${AGENT_NAME}' ${SAMPLE_INTERVAL} ${NUM_SAMPLES} ${csv_name}" &
        local mon_pid=$!

        # ab 부하 시작 (백그라운드)
        sleep 2
        log "  ab 부하 시작 (n=${AB_REQUESTS}, c=${AB_CONCURRENCY})"
        ab_exec "ab -n ${AB_REQUESTS} -c ${AB_CONCURRENCY} -k ${SERVER_URL} > /dev/null 2>&1" &
        local ab_pid=$!

        # 모니터 완료 대기
        wait "${mon_pid}" || true
        log "  모니터 완료"

        # ab 종료
        kill "${ab_pid}" 2>/dev/null || true
        wait "${ab_pid}" 2>/dev/null || true
        ab_exec "pkill -f 'ab -n' 2>/dev/null" || true
        log "  ab 종료"

        # 결과 수집
        local local_csv="${RESULT_HOST}/${csv_name}"
        kubectl cp "${NS_RESOURCE}/${mon_pod}:/results/${csv_name}" "${local_csv}" 2>/dev/null || \
            mon_exec "${mon_pod}" "cat /results/${csv_name}" > "${local_csv}" 2>/dev/null || true

        # per-trial 통계
        if [[ -f "${local_csv}" ]] && [[ $(wc -l < "${local_csv}") -gt 1 ]]; then
            local stats
            stats=$(compute_sample_stats "${local_csv}")
            echo "${LABEL},${trial},${stats}" >> "${summary}"

            local avg_ac std_ac avg_am std_am samples
            IFS=',' read -r avg_ac std_ac avg_am std_am samples <<< "${stats}"
            log "    agent_cpu=${avg_ac}+-${std_ac}%  agent_mem=${avg_am}+-${std_am}MB (n=${samples})"
        else
            warn "    결과 없음"
        fi

        sleep "${COOLDOWN}"
    done

    # 7. 정책 제거
    remove_policy

    # 8. Cross-trial 통계
    log "===== Cross-trial 통계 ====="
    local stats_csv="${RESULT_HOST}/${LABEL}_resource_stats.csv"
    compute_resource_stats "${summary}" "${stats_csv}"

    echo ""
    log "Per-trial summary:"
    column -t -s',' "${summary}" 2>/dev/null || cat "${summary}"
    echo ""
    log "Cross-trial stats:"
    column -t -s',' "${stats_csv}" 2>/dev/null || cat "${stats_csv}"
    echo ""
    log "완료 (label=${LABEL}, trials=${TRIALS})"
}

# ═══════════════════════════════════════════════════════════════════════
# CLEANUP
# ═══════════════════════════════════════════════════════════════════════
do_cleanup() {
    log "전체 정리"
    kubectl delete kloudknoxpolicy.security.boanlab.com --all -n "${NS}" --ignore-not-found 2>/dev/null || true
    if helm status falco -n falco &>/dev/null; then
        helm upgrade falco falcosecurity/falco -n falco --reuse-values \
            --set-json 'customRules={}' --wait --timeout 120s 2>/dev/null || true
    fi
    kubectl delete tracingpolicy --all --ignore-not-found 2>/dev/null || true
    kubectl delete namespace "${NS}" --ignore-not-found --grace-period=5 2>/dev/null || true
    kubectl delete namespace "${NS_RESOURCE}" --ignore-not-found --grace-period=5 2>/dev/null || true
    log "정리 완료"
}

# ═══════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════
case "${MODE}" in
    run)     do_run ;;
    deploy)  do_deploy ;;
    cleanup) do_cleanup ;;
    *)
        echo "사용법:"
        echo "  bash $0 run [vanilla|kloudknox|falco|tetragon]  # 벤치마크 실행"
        echo "  bash $0 deploy                                    # 인프라 배포"
        echo "  bash $0 cleanup                                   # 전체 정리"
        echo ""
        echo "환경변수:"
        echo "  TRIALS=3              반복 횟수"
        echo "  SAMPLE_INTERVAL=5     샘플링 간격 (초)"
        echo "  NUM_SAMPLES=12        샘플 수 (12 x 5s = 60s)"
        echo "  AB_REQUESTS=2000000   ab 총 요청 수"
        echo "  AB_CONCURRENCY=300    ab 동시 연결 수"
        echo "  WARMUP_REQUESTS=1000  워밍업 요청 수"
        echo "  COOLDOWN=10           trial 간 쿨다운 (초)"
        ;;
esac
