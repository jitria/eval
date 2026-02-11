#!/usr/bin/env bash
###############################################################################
# run_bench.sh — 5.8 Resource Overhead (v3)
#
# 실제 부하 중 보안 에이전트의 총 CPU/Memory 오버헤드 측정.
# 두 모드 각각 측정 후, 논문에 더 유리한 값을 선택.
#
# 변경 (v2 → v3):
#   1) Pod Density → Resource Overhead 재설계
#   2) 두 가지 모드: nginx (5.6 부하), syscall (5.7 부하)
#   3) 모니터 DaemonSet 전체 노드 배포 (nodeSelector 제거)
#   4) 5.6/5.7 YAML/정책 직접 참조 (새 정책 파일 안 만듦)
#
# 모드:
#   nginx   — 5.6 Nginx+wrk2 부하 중 compute-node-2 에이전트 측정
#   syscall — 5.7 lat_connect 부하 중 compute-node-1 에이전트 측정
#
# 사용법:
#   bash run_bench.sh nginx   [vanilla|kloudknox|falco|tetragon]
#   bash run_bench.sh syscall [vanilla|kloudknox|falco|tetragon]
#   bash run_bench.sh cleanup
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH56_DIR="$(cd "${SCRIPT_DIR}/../bench-5.6-nginx-rtt" && pwd)"
BENCH57_DIR="$(cd "${SCRIPT_DIR}/../bench-5.7-policy-scalability" && pwd)"

NS_RESOURCE="bench-resource"
NS_NGINX="bench-nginx"
NS_POLICY="bench-policy"
RESULT_HOST="/tmp/2026SoCC/bench-5.8"

MODE="${1:-help}"
LABEL="${2:-vanilla}"

# 에이전트 프로세스명 자동 매핑
AGENT_NAME=""
case "${LABEL}" in
    kloudknox) AGENT_NAME="kloudknox" ;;
    falco)     AGENT_NAME="falco" ;;
    tetragon)  AGENT_NAME="tetragon" ;;
esac

# ── 환경변수 ──────────────────────────────────────────────────────────
TRIALS="${TRIALS:-3}"
MEASURE_DURATION="${MEASURE_DURATION:-60}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-5}"
WARMUP_SEC="${WARMUP_SEC:-10}"

# nginx mode
WRK_CONNS="${WRK_CONNS:-100}"
WRK_RPS="${WRK_RPS:-10000}"
WRK_THREADS="${WRK_THREADS:-4}"

# syscall mode
TPUT_N="${TPUT_N:-1000}"
LMBENCH_REPS="${LMBENCH_REPS:-50}"
RULE_COUNT="${RULE_COUNT:-100}"
PIN_CORE="${PIN_CORE:-2}"

# ── 파생값 ────────────────────────────────────────────────────────────
NUM_SAMPLES=$(( MEASURE_DURATION / SAMPLE_INTERVAL ))
NGINX_URL="http://nginx-bench-svc.${NS_NGINX}.svc.cluster.local:80/"
WRK_POD="wrk2-client"
WORKLOAD_POD="workload"
SERVER_POD="tcp-server"
PIN_CMD=""

log()  { echo -e "\e[1;36m[5.8]\e[0m $*"; }
warn() { echo -e "\e[1;33m[5.8]\e[0m $*"; }

# ── exec 헬퍼 ─────────────────────────────────────────────────────────
mon_exec()    { local p="$1"; shift; kubectl -n "${NS_RESOURCE}" exec "${p}" -- bash -c "$*" 2>&1; }
wrk_exec()    { kubectl -n "${NS_NGINX}" exec "${WRK_POD}" -- bash -c "$1" 2>&1; }
work_exec()   { kubectl -n "${NS_POLICY}" exec "${WORKLOAD_POD}" -- bash -c "$1" 2>&1; }
server_exec() { kubectl -n "${NS_POLICY}" exec "${SERVER_POD}" -- bash -c "$1" 2>&1; }

# ── 모니터 Pod 검색 (노드별) ──────────────────────────────────────────
get_monitor_pod() {
    local node="$1"
    kubectl -n "${NS_RESOURCE}" get pods -l app=resource-monitor \
        --field-selector "spec.nodeName=${node}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# ── 캐시 초기화 ───────────────────────────────────────────────────────
flush_caches() {
    local mon_pod="$1"
    log "캐시 초기화 (drop_caches + sync)"
    mon_exec "${mon_pod}" 'sync && echo 3 > /proc/sys/vm/drop_caches' || true
    sleep 3
}

# ── 정책 검증 (공통) ──────────────────────────────────────────────────
verify_policy() {
    local ns="$1"
    [[ "${LABEL}" == "vanilla" ]] && return
    log "정책 적용 검증 (${LABEL})"
    local ok=false
    case "${LABEL}" in
        kloudknox)
            for _i in $(seq 1 15); do
                if kubectl -n "${ns}" get kloudknoxpolicy.security.boanlab.com -o name 2>/dev/null | grep -q .; then
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

# ── nginx 모드: 정책 적용/제거 ─────────────────────────────────────────
apply_policy_nginx() {
    [[ "${LABEL}" == "vanilla" ]] && return
    log "정책 적용 (${LABEL}, nginx mode)"
    case "${LABEL}" in
        kloudknox) kubectl apply -f "${BENCH56_DIR}/policies/kloudknox-policy.yaml" ;;
        falco)
            helm upgrade falco falcosecurity/falco -n falco --reuse-values \
                --set-file "customRules.bench-rules\.yaml=${BENCH56_DIR}/policies/falco-rules.yaml" \
                --wait --timeout 120s ;;
        tetragon) kubectl apply -f "${BENCH56_DIR}/policies/tetragon-policy.yaml" ;;
    esac
    verify_policy "${NS_NGINX}"
    log "정책 적용 완료"
}

remove_policy_nginx() {
    [[ "${LABEL}" == "vanilla" ]] && return
    log "정책 제거 (${LABEL}, nginx mode)"
    case "${LABEL}" in
        kloudknox)
            kubectl delete -f "${BENCH56_DIR}/policies/kloudknox-policy.yaml" --ignore-not-found 2>/dev/null || true ;;
        falco)
            if helm status falco -n falco &>/dev/null; then
                helm upgrade falco falcosecurity/falco -n falco --reuse-values \
                    --set-json 'customRules={}' --wait --timeout 120s 2>/dev/null || true
            fi ;;
        tetragon)
            kubectl delete -f "${BENCH56_DIR}/policies/tetragon-policy.yaml" --ignore-not-found 2>/dev/null || true ;;
    esac
    log "정책 제거 완료"
}

# ── syscall 모드: 정책 적용/제거 ───────────────────────────────────────
apply_policy_syscall() {
    [[ "${LABEL}" == "vanilla" ]] && return
    log "정책 적용 (${LABEL}, syscall mode, ${RULE_COUNT} rules)"
    mkdir -p "${RESULT_HOST}/rules"
    case "${LABEL}" in
        kloudknox)
            python3 "${BENCH57_DIR}/policies/generate_kloudknox_policies.py" \
                --count "${RULE_COUNT}" --namespace "${NS_POLICY}" \
                --output "${RESULT_HOST}/rules/kloudknox_${RULE_COUNT}.yaml"
            kubectl apply -f "${RESULT_HOST}/rules/kloudknox_${RULE_COUNT}.yaml"
            ;;
        falco)
            python3 "${BENCH57_DIR}/policies/generate_falco_rules.py" \
                --count "${RULE_COUNT}" \
                --output "${RESULT_HOST}/rules/falco_${RULE_COUNT}.yaml"
            helm upgrade falco falcosecurity/falco -n falco --reuse-values \
                --set-file "customRules.bench-rules\.yaml=${RESULT_HOST}/rules/falco_${RULE_COUNT}.yaml" \
                --wait --timeout 120s
            ;;
        tetragon)
            python3 "${BENCH57_DIR}/policies/generate_tetragon_policies.py" \
                --count "${RULE_COUNT}" \
                --output "${RESULT_HOST}/rules/tetragon_${RULE_COUNT}.yaml"
            kubectl apply -f "${RESULT_HOST}/rules/tetragon_${RULE_COUNT}.yaml"
            ;;
    esac
    verify_policy "${NS_POLICY}"
    log "정책 적용 완료"
}

remove_policy_syscall() {
    [[ "${LABEL}" == "vanilla" ]] && return
    log "정책 제거 (${LABEL}, syscall mode)"
    case "${LABEL}" in
        kloudknox)
            kubectl delete -f "${RESULT_HOST}/rules/kloudknox_${RULE_COUNT}.yaml" --ignore-not-found 2>/dev/null || true ;;
        falco)
            if helm status falco -n falco &>/dev/null; then
                helm upgrade falco falcosecurity/falco -n falco --reuse-values \
                    --set-json 'customRules={}' --wait --timeout 120s 2>/dev/null || true
            fi ;;
        tetragon)
            kubectl delete -f "${RESULT_HOST}/rules/tetragon_${RULE_COUNT}.yaml" --ignore-not-found 2>/dev/null || true ;;
    esac
    log "정책 제거 완료"
}

# ── 인프라 배포 ────────────────────────────────────────────────────────
deploy_monitor() {
    log "모니터 DaemonSet 배포 (${NS_RESOURCE})"
    kubectl apply -f "${SCRIPT_DIR}/00-namespace.yaml"
    kubectl apply -f "${SCRIPT_DIR}/01-monitor-daemonset.yaml"
    log "DaemonSet 대기..."
    kubectl -n "${NS_RESOURCE}" rollout status daemonset/resource-monitor --timeout=120s
    log "모니터 배포 완료"
    kubectl -n "${NS_RESOURCE}" get pods -o wide
}

deploy_nginx_infra() {
    log "Nginx 인프라 배포 (5.6)"
    kubectl apply -f "${BENCH56_DIR}/00-namespace.yaml"
    kubectl apply -f "${BENCH56_DIR}/nginx-configmap.yaml"
    kubectl apply -f "${BENCH56_DIR}/01-nginx-deployment.yaml"
    kubectl apply -f "${BENCH56_DIR}/02-wrk2-pod.yaml"
    log "Nginx 준비 대기..."
    kubectl -n "${NS_NGINX}" rollout status deployment/nginx-bench --timeout=120s
    log "wrk2 Pod 대기..."
    kubectl -n "${NS_NGINX}" wait --for=condition=Ready "pod/${WRK_POD}" --timeout=120s
    wrk_exec 'ls -la /tools/bin/wrk' || { warn "wrk2 바이너리 없음"; return 1; }
    log "Nginx 인프라 배포 완료"
}

deploy_syscall_infra() {
    log "syscall 인프라 배포 (5.7)"
    kubectl apply -f "${BENCH57_DIR}/00-namespace.yaml"
    kubectl apply -f "${BENCH57_DIR}/01-bpftrace-daemonset.yaml"
    kubectl apply -f "${BENCH57_DIR}/02-tcp-server-pod.yaml"
    log "DaemonSet 대기..."
    kubectl -n "${NS_POLICY}" rollout status daemonset/bpftrace-tracer --timeout=120s
    log "workload Pod 대기..."
    kubectl -n "${NS_POLICY}" wait --for=condition=Ready "pod/${WORKLOAD_POD}" --timeout=120s
    log "tcp-server Pod 대기..."
    kubectl -n "${NS_POLICY}" wait --for=condition=Ready "pod/${SERVER_POD}" --timeout=120s
    work_exec 'ls -la /tools/bin/lat_connect' || { warn "lat_connect 바이너리 없음"; return 1; }
    server_exec 'ls -la /tools/bin/bw_tcp' || { warn "bw_tcp 바이너리 없음"; return 1; }
    log "syscall 인프라 배포 완료"
}

# ── CPU pinning (syscall) ──────────────────────────────────────────────
setup_cpu_pin() {
    if work_exec "taskset -c ${PIN_CORE} echo ok" &>/dev/null; then
        PIN_CMD="taskset -c ${PIN_CORE}"
        log "CPU pinning 활성화: core ${PIN_CORE}"
    else
        warn "taskset 사용 불가 — CPU pinning 없이 실행"
        PIN_CMD=""
    fi
}

# ── per-trial 통계 (샘플 CSV → avg/stddev) ────────────────────────────
compute_sample_stats() {
    local csv="$1"
    # 입력: timestamp,workload,agent_cpu,agent_mem,node_cpu,node_mem_used,node_mem_total
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

# ── cross-trial 통계 ──────────────────────────────────────────────────
compute_cross_trial_stats() {
    local summary_csv="$1" stats_csv="$2"

    echo "label,trials,avg_agent_cpu,std_agent_cpu,avg_agent_mem,std_agent_mem,avg_node_cpu,std_node_cpu,avg_node_mem,std_node_mem" > "${stats_csv}"

    # summary: label,trial,avg_ac,std_ac,avg_am,std_am,avg_nc,std_nc,avg_nm,std_nm,samples
    # cross-trial: avg/std across trials의 per-trial avg ($3,$5,$7,$9)
    awk -F',' -v lab="${LABEL}" '
    NR > 1 {
        n++
        sac+=$3; sam+=$5; snc+=$7; snm+=$9
        sac2+=$3*$3; sam2+=$5*$5; snc2+=$7*$7; snm2+=$9*$9
    }
    END {
        if (n == 0) { printf "%s,0,0,0,0,0,0,0,0,0\n",lab; exit }
        aac=sac/n; aam=sam/n; anc=snc/n; anm=snm/n
        vac=(sac2/n)-(aac*aac); dac=sqrt(vac>0?vac:0)
        vam=(sam2/n)-(aam*aam); dam=sqrt(vam>0?vam:0)
        vnc=(snc2/n)-(anc*anc); dnc=sqrt(vnc>0?vnc:0)
        vnm=(snm2/n)-(anm*anm); dnm=sqrt(vnm>0?vnm:0)
        printf "%s,%d,%.2f,%.2f,%.1f,%.1f,%.1f,%.1f,%.0f,%.0f\n",
            lab,n,aac,dac,aam,dam,anc,dnc,anm,dnm
    }' "${summary_csv}" >> "${stats_csv}"
}

# ═══════════════════════════════════════════════════════════════════════
# NGINX MODE
# ═══════════════════════════════════════════════════════════════════════
do_nginx() {
    log "===== Nginx Mode (label=${LABEL}) ====="
    mkdir -p "${RESULT_HOST}"

    # 1. 인프라 배포
    deploy_monitor
    deploy_nginx_infra

    # 2. 정책 적용
    apply_policy_nginx

    # 3. 서버 연결 확인
    log "서버 연결 확인..."
    local connected=false
    for i in $(seq 1 30); do
        if wrk_exec "/tools/bin/wrk -t1 -c1 -d1s -R1 ${NGINX_URL}" &>/dev/null; then
            connected=true; break
        fi
        sleep 1
    done
    [[ "${connected}" == "true" ]] || { warn "서버 연결 실패"; return 1; }
    log "서버 연결 확인 완료"

    # 4. 워밍업
    log "===== Warm-up (${WARMUP_SEC}초, RPS=${WRK_RPS}, c=${WRK_CONNS}) ====="
    wrk_exec "/tools/bin/wrk -t${WRK_THREADS} -c${WRK_CONNS} -d${WARMUP_SEC}s -R${WRK_RPS} ${NGINX_URL} > /dev/null 2>&1" || true
    log "Warm-up 완료"
    sleep 5

    # 5. 모니터 Pod 찾기 (compute-node-2: Nginx 쪽 에이전트)
    local mon_pod
    mon_pod=$(get_monitor_pod "compute-node-2")
    [[ -n "${mon_pod}" ]] || { warn "monitor pod not found on compute-node-2"; return 1; }
    log "Monitor Pod: ${mon_pod} (compute-node-2)"

    local summary="${RESULT_HOST}/${LABEL}_nginx_summary.csv"
    echo "label,trial,avg_agent_cpu,std_agent_cpu,avg_agent_mem,std_agent_mem,avg_node_cpu,std_node_cpu,avg_node_mem,std_node_mem,samples" > "${summary}"

    # 6. Trial 루프
    for trial in $(seq 1 "${TRIALS}"); do
        log "===== Trial ${trial}/${TRIALS} ====="
        flush_caches "${mon_pod}"

        local csv_name="${LABEL}_nginx_t${trial}.csv"
        local wrk_duration=$((MEASURE_DURATION + 20))

        # wrk2 부하 백그라운드 실행
        log "  wrk2 부하 시작 (RPS=${WRK_RPS}, c=${WRK_CONNS}, ${wrk_duration}s)"
        wrk_exec "nohup /tools/bin/wrk -t${WRK_THREADS} -c${WRK_CONNS} -d${wrk_duration}s -R${WRK_RPS} ${NGINX_URL} > /dev/null 2>&1 &"
        sleep 2

        # 모니터 실행 (blocking, ${NUM_SAMPLES} samples)
        log "  모니터링 (${NUM_SAMPLES} samples x ${SAMPLE_INTERVAL}s = ${MEASURE_DURATION}s)"
        mon_exec "${mon_pod}" "bash /scripts/monitor_in_pod.sh '${AGENT_NAME}' ${SAMPLE_INTERVAL} ${NUM_SAMPLES} nginx ${csv_name}" || true

        # wrk2 정리
        wrk_exec "pkill -f wrk 2>/dev/null" || true

        # 결과 수집 (kubectl cp → cat fallback)
        local local_csv="${RESULT_HOST}/${csv_name}"
        kubectl cp "${NS_RESOURCE}/${mon_pod}:/results/${csv_name}" "${local_csv}" 2>/dev/null || \
            mon_exec "${mon_pod}" "cat /results/${csv_name}" > "${local_csv}" 2>/dev/null || true

        # per-trial 통계
        if [[ -f "${local_csv}" ]] && [[ $(wc -l < "${local_csv}") -gt 1 ]]; then
            local stats
            stats=$(compute_sample_stats "${local_csv}")
            echo "${LABEL},${trial},${stats}" >> "${summary}"

            local avg_ac std_ac avg_am std_am avg_nc std_nc avg_nm std_nm samples
            IFS=',' read -r avg_ac std_ac avg_am std_am avg_nc std_nc avg_nm std_nm samples <<< "${stats}"
            log "    agent_cpu=${avg_ac}±${std_ac}%  agent_mem=${avg_am}±${std_am}MB  node_cpu=${avg_nc}±${std_nc}%  node_mem=${avg_nm}±${std_nm}MB (n=${samples})"
        else
            warn "    결과 없음"
        fi

        sleep 5
    done

    # 7. Cross-trial 통계
    log "===== Cross-trial 통계 ====="
    local stats_csv="${RESULT_HOST}/${LABEL}_nginx_stats.csv"
    compute_cross_trial_stats "${summary}" "${stats_csv}"

    echo ""
    log "Per-trial:"
    column -t -s',' "${summary}" 2>/dev/null || cat "${summary}"
    echo ""
    log "Cross-trial (avg ± stddev):"
    column -t -s',' "${stats_csv}" 2>/dev/null || cat "${stats_csv}"

    # 8. 정책 제거
    remove_policy_nginx

    echo ""
    log "완료 (mode=nginx, label=${LABEL}, trials=${TRIALS}, rps=${WRK_RPS}, conns=${WRK_CONNS})"
}

# ═══════════════════════════════════════════════════════════════════════
# SYSCALL MODE
# ═══════════════════════════════════════════════════════════════════════
do_syscall() {
    log "===== Syscall Mode (label=${LABEL}) ====="
    mkdir -p "${RESULT_HOST}"

    # 1. 인프라 배포
    deploy_monitor
    deploy_syscall_infra

    # 2. CPU pinning
    setup_cpu_pin

    # 3. 정책 적용
    apply_policy_syscall

    # 4. TCP 서버 시작
    local server_ip
    server_ip=$(kubectl -n "${NS_POLICY}" get pod tcp-server -o jsonpath='{.status.podIP}')
    log "TCP 서버 시작 (bw_tcp -s on ${server_ip})"
    server_exec 'nohup /tools/bin/bw_tcp -s >/dev/null 2>&1 &'
    sleep 2

    # 5. 서버 연결 확인
    log "서버 연결 확인..."
    local connected=false
    for i in $(seq 1 30); do
        if work_exec "${PIN_CMD} /tools/bin/lat_connect ${server_ip} 2>/dev/null" &>/dev/null; then
            connected=true; break
        fi
        sleep 1
    done
    [[ "${connected}" == "true" ]] || { warn "서버 연결 실패 (${server_ip})"; return 1; }
    log "서버 연결 확인 완료 (${server_ip})"

    # 6. 워밍업
    log "===== Warm-up (${WARMUP_SEC}초) ====="
    work_exec "
timeout ${WARMUP_SEC} bash -c '
while true; do
    ${PIN_CMD} /tools/bin/lat_connect ${server_ip} >/dev/null 2>&1
done
' || true
echo 'warm-up done'
"
    log "Warm-up 완료"
    sleep 5

    # 7. 모니터 Pod 찾기 (compute-node-1: 워크로드 쪽 에이전트)
    local mon_pod
    mon_pod=$(get_monitor_pod "compute-node-1")
    [[ -n "${mon_pod}" ]] || { warn "monitor pod not found on compute-node-1"; return 1; }
    log "Monitor Pod: ${mon_pod} (compute-node-1)"

    local summary="${RESULT_HOST}/${LABEL}_syscall_summary.csv"
    echo "label,trial,avg_agent_cpu,std_agent_cpu,avg_agent_mem,std_agent_mem,avg_node_cpu,std_node_cpu,avg_node_mem,std_node_mem,samples" > "${summary}"

    # 8. Trial 루프
    for trial in $(seq 1 "${TRIALS}"); do
        log "===== Trial ${trial}/${TRIALS} ====="
        flush_caches "${mon_pod}"

        local csv_name="${LABEL}_syscall_t${trial}.csv"
        local load_duration=$((MEASURE_DURATION + 20))

        # lat_connect 부하 백그라운드 실행
        log "  lat_connect 부하 시작 (N=${TPUT_N}, ${load_duration}s)"
        work_exec "nohup timeout ${load_duration} bash -c '
while true; do
    ${PIN_CMD} /tools/bin/lat_connect -N ${TPUT_N} ${server_ip} >/dev/null 2>&1
done
' > /dev/null 2>&1 &"
        sleep 2

        # 모니터 실행 (blocking, ${NUM_SAMPLES} samples)
        log "  모니터링 (${NUM_SAMPLES} samples x ${SAMPLE_INTERVAL}s = ${MEASURE_DURATION}s)"
        mon_exec "${mon_pod}" "bash /scripts/monitor_in_pod.sh '${AGENT_NAME}' ${SAMPLE_INTERVAL} ${NUM_SAMPLES} syscall ${csv_name}" || true

        # lat_connect 정리
        work_exec "pkill -f lat_connect 2>/dev/null" || true

        # 결과 수집 (kubectl cp → cat fallback)
        local local_csv="${RESULT_HOST}/${csv_name}"
        kubectl cp "${NS_RESOURCE}/${mon_pod}:/results/${csv_name}" "${local_csv}" 2>/dev/null || \
            mon_exec "${mon_pod}" "cat /results/${csv_name}" > "${local_csv}" 2>/dev/null || true

        # per-trial 통계
        if [[ -f "${local_csv}" ]] && [[ $(wc -l < "${local_csv}") -gt 1 ]]; then
            local stats
            stats=$(compute_sample_stats "${local_csv}")
            echo "${LABEL},${trial},${stats}" >> "${summary}"

            local avg_ac std_ac avg_am std_am avg_nc std_nc avg_nm std_nm samples
            IFS=',' read -r avg_ac std_ac avg_am std_am avg_nc std_nc avg_nm std_nm samples <<< "${stats}"
            log "    agent_cpu=${avg_ac}±${std_ac}%  agent_mem=${avg_am}±${std_am}MB  node_cpu=${avg_nc}±${std_nc}%  node_mem=${avg_nm}±${std_nm}MB (n=${samples})"
        else
            warn "    결과 없음"
        fi

        sleep 5
    done

    # 9. TCP 서버 종료
    server_exec 'pkill -f "bw_tcp" 2>/dev/null || true' || true

    # 10. Cross-trial 통계
    log "===== Cross-trial 통계 ====="
    local stats_csv="${RESULT_HOST}/${LABEL}_syscall_stats.csv"
    compute_cross_trial_stats "${summary}" "${stats_csv}"

    echo ""
    log "Per-trial:"
    column -t -s',' "${summary}" 2>/dev/null || cat "${summary}"
    echo ""
    log "Cross-trial (avg ± stddev):"
    column -t -s',' "${stats_csv}" 2>/dev/null || cat "${stats_csv}"

    # 11. 정책 제거
    remove_policy_syscall

    echo ""
    log "완료 (mode=syscall, label=${LABEL}, trials=${TRIALS}, N=${TPUT_N}, rules=${RULE_COUNT})"
}

# ═══════════════════════════════════════════════════════════════════════
# CLEANUP
# ═══════════════════════════════════════════════════════════════════════
do_cleanup() {
    log "전체 정리"
    # 모든 정책 제거
    kubectl delete kloudknoxpolicy.security.boanlab.com --all -n "${NS_NGINX}" --ignore-not-found 2>/dev/null || true
    kubectl delete kloudknoxpolicy.security.boanlab.com --all -n "${NS_POLICY}" --ignore-not-found 2>/dev/null || true
    if helm status falco -n falco &>/dev/null; then
        helm upgrade falco falcosecurity/falco -n falco --reuse-values \
            --set-json 'customRules={}' --wait --timeout 120s 2>/dev/null || true
    fi
    kubectl delete tracingpolicy --all --ignore-not-found 2>/dev/null || true
    # 네임스페이스 삭제
    kubectl delete namespace "${NS_RESOURCE}" --ignore-not-found --grace-period=5 2>/dev/null || true
    kubectl delete namespace "${NS_NGINX}" --ignore-not-found --grace-period=5 2>/dev/null || true
    kubectl delete namespace "${NS_POLICY}" --ignore-not-found --grace-period=5 2>/dev/null || true
    log "정리 완료"
}

# ═══════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════
case "${MODE}" in
    nginx)   do_nginx ;;
    syscall) do_syscall ;;
    cleanup) do_cleanup ;;
    *)
        echo "사용법:"
        echo "  bash $0 nginx   [vanilla|kloudknox|falco|tetragon]  # Nginx 부하 중 리소스 측정"
        echo "  bash $0 syscall [vanilla|kloudknox|falco|tetragon]  # syscall 부하 중 리소스 측정"
        echo "  bash $0 cleanup                                      # 전체 정리"
        echo ""
        echo "환경변수:"
        echo "  TRIALS=3              반복 횟수"
        echo "  MEASURE_DURATION=60   측정 시간 (초)"
        echo "  SAMPLE_INTERVAL=5     샘플링 간격 (초)"
        echo "  WARMUP_SEC=10         워밍업 시간 (초)"
        echo "  # nginx:"
        echo "  WRK_CONNS=100         wrk2 동시 연결"
        echo "  WRK_RPS=10000         wrk2 목표 RPS"
        echo "  WRK_THREADS=4         wrk2 스레드"
        echo "  # syscall:"
        echo "  TPUT_N=1000           lat_connect -N 반복"
        echo "  LMBENCH_REPS=50       lat_connect 반복 횟수"
        echo "  RULE_COUNT=100        정책 규칙 수"
        echo "  PIN_CORE=2            CPU pinning 코어"
        ;;
esac
