#!/usr/bin/env bash
###############################################################################
# run_bench.sh — 5.5 Syscall Latency (v5 - 단일 노드)
#
# 개선 사항 (v4 → v5):
#   - connect를 cross-node → 단일 노드(compute-node-1)로 변경
#     네트워크 홉 제거 → 순수 syscall 오버헤드만 측정
#   - trial별 즉시 통계 표시 (p50/p99/avg ± stddev)
#
# 기존 유지:
#   1) openat 샘플 수 증가: OPENAT_MULT 배수
#   2) trial 간 독립성: drop_caches + sync + sleep
#   3) IQR 기반 outlier 필터링: raw/iqr 양쪽 통계 출력
#   4) CPU pinning: taskset으로 lmbench를 특정 코어에 고정
#   5) 결과 전송: kubectl cp 우선, 실패 시 cat fallback
#   6) comm 필터, printf 개별 ns, 실제 워밍업
#
# 아키텍처 (단일 노드):
#   compute-node-1
#   ├── bpftrace DaemonSet (privileged, hostPID)
#   │   └── trace_{execve,openat,connect}.bt
#   ├── workload Pod (lmbench)
#   │   ├── lat_proc exec       (execve)
#   │   ├── lat_syscall open    (openat)
#   │   └── lat_connect <서버IP> (connect, same-node)
#   └── tcp-server Pod
#       └── bw_tcp -s (TCP accept 서버)
#
# 사용법:
#   bash run_bench.sh run   [vanilla|kloudknox|falco|tetragon]
#   bash run_bench.sh deploy
#   bash run_bench.sh cleanup
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NS="bench-syscall"
RESULT_HOST="/tmp/2026SoCC/bench-5.5"
LABEL="${2:-vanilla}"
TRIALS="${TRIALS:-5}"
WARMUP_SEC="${WARMUP_SEC:-30}"
LMBENCH_REPS="${LMBENCH_REPS:-10}"
OPENAT_MULT="${OPENAT_MULT:-10}"   # openat은 샘플이 적으므로 추가 배수
PIN_CORE="${PIN_CORE:-2}"          # CPU pinning 코어 (0=IRQ 처리용 회피)

log()  { echo -e "\e[1;36m[5.5]\e[0m $*"; }
warn() { echo -e "\e[1;33m[5.5]\e[0m $*"; }

TRACER_POD=""
WORKLOAD_POD="workload"
SERVER_POD="tcp-server"
SERVER_IP=""
PIN_CMD=""

get_tracer_pod() {
    kubectl -n "${NS}" get pods -l app=bpftrace-tracer \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

tracer_exec() { kubectl -n "${NS}" exec "${TRACER_POD}" -- bash -c "$1" 2>&1; }
work_exec()   { kubectl -n "${NS}" exec "${WORKLOAD_POD}" -- bash -c "$1" 2>&1; }
server_exec() { kubectl -n "${NS}" exec "${SERVER_POD}" -- bash -c "$1" 2>&1; }

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

# ── CPU pinning 설정 ─────────────────────────────────────────────────
setup_cpu_pin() {
    if work_exec "taskset -c ${PIN_CORE} echo ok" &>/dev/null; then
        PIN_CMD="taskset -c ${PIN_CORE}"
        log "CPU pinning 활성화: core ${PIN_CORE}"
    else
        warn "taskset 사용 불가 — CPU pinning 없이 실행"
        PIN_CMD=""
    fi
}

# ── 통계 계산 (raw / iqr) ────────────────────────────────────────────
compute_stats() {
    local raw_file="$1" filter="${2:-raw}"
    local sorted="${raw_file}.sorted"

    grep -E '^[0-9]+$' "${raw_file}" | sort -n > "${sorted}"
    local count
    count=$(wc -l < "${sorted}")

    if [[ ${count} -eq 0 ]]; then
        echo "0,0,0,0,0,0,0"
        return
    fi

    if [[ "${filter}" == "iqr" ]]; then
        awk '
        { a[NR] = $1 }
        END {
            n = NR
            q1_idx = int(n * 0.25); if (q1_idx < 1) q1_idx = 1
            q3_idx = int(n * 0.75); if (q3_idx < 1) q3_idx = 1
            q1 = a[q1_idx]; q3 = a[q3_idx]
            iqr = q3 - q1
            lower = q1 - 1.5 * iqr
            upper = q3 + 1.5 * iqr

            fn = 0; fsum = 0; fsumsq = 0
            for (i = 1; i <= n; i++) {
                if (a[i] >= lower && a[i] <= upper) {
                    fn++
                    fa[fn] = a[i]
                    fsum += a[i]
                    fsumsq += a[i] * a[i]
                }
            }

            if (fn == 0) { printf "0,0,0,0,0,0,0\n"; exit }

            avg = fsum / fn
            variance = (fsumsq / fn) - (avg * avg)
            stddev = sqrt(variance > 0 ? variance : 0)
            p50_idx = int(fn * 0.50); if (p50_idx < 1) p50_idx = 1
            p99_idx = int(fn * 0.99); if (p99_idx < 1) p99_idx = 1

            printf "%d,%d,%d,%d,%d,%d,%d\n", avg, fa[p50_idx], fa[p99_idx], fa[1], fa[fn], fn, stddev
        }' "${sorted}"
    else
        awk '
        {
            a[NR] = $1
            sum += $1
            sumsq += ($1 * $1)
        }
        END {
            n = NR
            avg = sum / n
            variance = (sumsq / n) - (avg * avg)
            stddev = sqrt(variance > 0 ? variance : 0)

            p50_idx = int(n * 0.50); if (p50_idx < 1) p50_idx = 1
            p99_idx = int(n * 0.99); if (p99_idx < 1) p99_idx = 1

            printf "%d,%d,%d,%d,%d,%d,%d\n", avg, a[p50_idx], a[p99_idx], a[1], a[n], n, stddev
        }' "${sorted}"
    fi
}

# ── cross-trial 통계 계산 ────────────────────────────────────────────
compute_cross_trial_stats() {
    local summary_csv="$1" stats_csv="$2" filter="$3"

    echo "label,syscall,trials,filter,avg_p50_ns,std_p50_ns,avg_p99_ns,std_p99_ns,avg_mean_ns,std_mean_ns,avg_count,std_count" > "${stats_csv}"

    for sc in execve openat connect; do
        grep "^${LABEL},${sc},[0-9]*,${filter}," "${summary_csv}" 2>/dev/null | awk -F',' \
            -v label="${LABEL}" -v sc="${sc}" -v filter="${filter}" '
        {
            n++
            sp50  += $6;  sq50  += $6*$6
            sp99  += $7;  sq99  += $7*$7
            smean += $5;  sqmean += $5*$5
            scnt  += $10; sqcnt += $10*$10
        }
        END {
            if (n == 0) exit
            ap50 = sp50/n;  ap99  = sp99/n
            amean = smean/n; acnt = scnt/n
            v50   = sq50/n  - ap50*ap50;   sd50   = sqrt(v50   > 0 ? v50   : 0)
            v99   = sq99/n  - ap99*ap99;   sd99   = sqrt(v99   > 0 ? v99   : 0)
            vmean = sqmean/n - amean*amean; sdmean = sqrt(vmean > 0 ? vmean : 0)
            vcnt  = sqcnt/n - acnt*acnt;    sdcnt  = sqrt(vcnt  > 0 ? vcnt  : 0)
            printf "%s,%s,%d,%s,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f\n",
                label, sc, n, filter,
                ap50, sd50, ap99, sd99,
                amean, sdmean, acnt, sdcnt
        }' >> "${stats_csv}" || true
    done
}

# ── deploy ───────────────────────────────────────────────────────────
do_deploy() {
    log "배포 시작"
    kubectl apply -f "${SCRIPT_DIR}/00-namespace.yaml"
    kubectl apply -f "${SCRIPT_DIR}/01-bpftrace-daemonset.yaml"
    kubectl apply -f "${SCRIPT_DIR}/02-tcp-server-pod.yaml"

    log "DaemonSet 대기..."
    kubectl -n "${NS}" rollout status daemonset/bpftrace-tracer --timeout=120s
    log "workload Pod 대기..."
    kubectl -n "${NS}" wait --for=condition=Ready pod/workload --timeout=120s
    log "tcp-server Pod 대기..."
    kubectl -n "${NS}" wait --for=condition=Ready pod/tcp-server --timeout=120s

    TRACER_POD=$(get_tracer_pod)
    log "bpftrace 설치 (${TRACER_POD})"
    tracer_exec 'apt-get update -qq && apt-get install -y -qq bpftrace >/dev/null 2>&1 && bpftrace --version'

    # 서버 Pod IP
    SERVER_IP=$(kubectl -n "${NS}" get pod tcp-server -o jsonpath='{.status.podIP}')
    log "서버 Pod IP: ${SERVER_IP} (compute-node-1, same-node)"

    log "Pod 배치 확인:"
    kubectl -n "${NS}" get pods -o wide

    # 바이너리 확인
    work_exec 'ls -la /tools/bin/lat_proc /tools/bin/lat_syscall /tools/bin/lat_connect' || { warn "lmbench 바이너리 없음"; return 1; }
    server_exec 'ls -la /tools/bin/bw_tcp' || { warn "bw_tcp 바이너리 없음"; return 1; }
    log "deploy 완료"
}

# ── trial 간 캐시 초기화 ─────────────────────────────────────────────
flush_caches() {
    log "캐시 초기화 (drop_caches + sync)"
    tracer_exec 'sync && echo 3 > /proc/sys/vm/drop_caches' || true
    sleep 5
}

# ── 단일 syscall 측정 ───────────────────────────────────────────────
measure_one() {
    local sc="$1" bt="$2" lmbench_cmd="$3" trial="$4" reps="${5:-${LMBENCH_REPS}}"
    local trace_file="/results/${LABEL}_${sc}_trial${trial}.log"

    # 1) bpftrace 시작 ("Attaching" 메시지로 attach 완료 확인)
    tracer_exec "
cat > /tmp/run_bt.sh << 'BTEOF'
#!/bin/bash
nohup bpftrace /scripts/${bt} > ${trace_file} 2>&1 &
echo \$! > /tmp/bpf_pid
for _i in \$(seq 1 30); do
    if grep -q 'Attaching' ${trace_file} 2>/dev/null; then
        break
    fi
    sleep 1
done
if ! grep -q 'Attaching' ${trace_file} 2>/dev/null; then
    echo 'WARN: bpftrace attach not detected after 30s' >&2
fi
BTEOF
bash /tmp/run_bt.sh
"

    # 2) lmbench 반복 실행
    log "  [trial ${trial}] ${sc}: ${lmbench_cmd} x${reps}"
    for i in $(seq 1 "${reps}"); do
        work_exec "${lmbench_cmd} 2>/dev/null" || true
    done

    # 3) bpftrace 종료
    sleep 1
    tracer_exec '
BPF_PID=$(cat /tmp/bpf_pid 2>/dev/null)
if [ -n "${BPF_PID}" ] && kill -0 ${BPF_PID} 2>/dev/null; then
    kill -INT ${BPF_PID} 2>/dev/null || true
    sleep 2
fi
' || true
}

# ── run ──────────────────────────────────────────────────────────────
do_run() {
    do_deploy
    TRACER_POD=$(get_tracer_pod)
    SERVER_IP=$(kubectl -n "${NS}" get pod tcp-server -o jsonpath='{.status.podIP}')
    mkdir -p "${RESULT_HOST}"

    # CPU pinning
    setup_cpu_pin

    # 정책 적용
    apply_policy

    # 시스템 정보
    tracer_exec "{ uname -a; lscpu | head -20; free -h; } > /results/${LABEL}_sysinfo.txt"

    # TCP 서버 시작 (서버 Pod, compute-node-1 same-node)
    log "TCP 서버 시작 (bw_tcp -s on ${SERVER_IP}, same-node)"
    server_exec 'nohup /tools/bin/bw_tcp -s >/dev/null 2>&1 &'
    sleep 2

    # 서버 연결 확인
    log "서버 연결 확인..."
    local connected=false
    for i in $(seq 1 30); do
        if work_exec "${PIN_CMD} /tools/bin/lat_connect ${SERVER_IP} 2>/dev/null" &>/dev/null; then
            connected=true
            break
        fi
        sleep 1
    done
    if [[ "${connected}" != "true" ]]; then
        warn "서버 연결 실패 (${SERVER_IP}, 30초 타임아웃)"
        return 1
    fi
    log "서버 연결 확인 완료 (${SERVER_IP})"

    # ── 워밍업 ────────────────────────────────────────────────────────
    log "===== Warm-up (${WARMUP_SEC}초 동안 lmbench 반복) ====="
    work_exec "
timeout ${WARMUP_SEC} bash -c '
while true; do
    ${PIN_CMD} /tools/bin/lat_proc exec     >/dev/null 2>&1
    ${PIN_CMD} /tools/bin/lat_syscall open  >/dev/null 2>&1
    ${PIN_CMD} /tools/bin/lat_connect ${SERVER_IP} >/dev/null 2>&1
done
' || true
echo 'warm-up done'
"
    log "Warm-up 완료"

    # 워밍업 후 캐시 초기화 → 모든 trial이 동일 조건에서 시작
    flush_caches

    # openat 반복 횟수
    local openat_reps=$((LMBENCH_REPS * OPENAT_MULT))

    # ── 결과 CSV 초기화 ──────────────────────────────────────────────
    local summary="${RESULT_HOST}/${LABEL}_summary.csv"
    echo "label,syscall,trial,filter,avg_ns,p50_ns,p99_ns,min_ns,max_ns,count,stddev_ns" > "${summary}"

    # ── 측정 + 즉시 수집/통계 ──────────────────────────────────────────
    for trial in $(seq 1 "${TRIALS}"); do
        log "===== Trial ${trial}/${TRIALS} ====="

        for sc_info in "execve:trace_execve.bt:${PIN_CMD} /tools/bin/lat_proc exec:${LMBENCH_REPS}" \
                       "openat:trace_openat.bt:${PIN_CMD} /tools/bin/lat_syscall open:${openat_reps}" \
                       "connect:trace_connect.bt:${PIN_CMD} /tools/bin/lat_connect ${SERVER_IP}:${LMBENCH_REPS}"; do
            local sc bt cmd reps_n
            sc="${sc_info%%:*}";       sc_info="${sc_info#*:}"
            bt="${sc_info%%:*}";       sc_info="${sc_info#*:}"
            reps_n="${sc_info##*:}"
            cmd="${sc_info%:*}"

            measure_one "${sc}" "${bt}" "${cmd}" "${trial}" "${reps_n}"
            sleep 1

            # 즉시 결과 수집
            local remote="/results/${LABEL}_${sc}_trial${trial}.log"
            local local_f="${RESULT_HOST}/${LABEL}_${sc}_trial${trial}.log"
            kubectl cp "${NS}/${TRACER_POD}:${remote}" "${local_f}" 2>/dev/null || \
                tracer_exec "cat ${remote}" > "${local_f}" 2>/dev/null || true

            # 즉시 통계 계산 + 표시
            if [[ -f "${local_f}" && -s "${local_f}" ]]; then
                local raw_stats iqr_stats
                raw_stats=$(compute_stats "${local_f}" "raw")
                iqr_stats=$(compute_stats "${local_f}" "iqr")
                echo "${LABEL},${sc},${trial},raw,${raw_stats}" >> "${summary}"
                echo "${LABEL},${sc},${trial},iqr,${iqr_stats}" >> "${summary}"

                # 인라인 표시: p50/p99/avg ± stddev (IQR filtered)
                local i_avg i_p50 i_p99 i_cnt i_sd
                i_avg=$(echo "${iqr_stats}" | cut -d, -f1)
                i_p50=$(echo "${iqr_stats}" | cut -d, -f2)
                i_p99=$(echo "${iqr_stats}" | cut -d, -f3)
                i_cnt=$(echo "${iqr_stats}" | cut -d, -f6)
                i_sd=$(echo "${iqr_stats}"  | cut -d, -f7)
                log "    ${sc}: avg=${i_avg}±${i_sd}ns  p50=${i_p50}ns  p99=${i_p99}ns  (n=${i_cnt})"
            else
                warn "    ${sc}: 결과 없음"
            fi

            sleep 2
        done

        # trial 간 캐시 초기화 (마지막 trial 제외)
        if [[ ${trial} -lt ${TRIALS} ]]; then
            flush_caches
        fi
    done

    # TCP 서버 종료
    server_exec 'pkill -f "bw_tcp" 2>/dev/null || true' || true

    # ── cross-trial 통계 ──────────────────────────────────────────────
    log "===== Cross-trial 통계 계산 ====="
    local stats_iqr="${RESULT_HOST}/${LABEL}_stats_iqr.csv"
    local stats_raw="${RESULT_HOST}/${LABEL}_stats_raw.csv"
    compute_cross_trial_stats "${summary}" "${stats_iqr}" "iqr"
    compute_cross_trial_stats "${summary}" "${stats_raw}" "raw"

    echo ""
    log "Per-trial 요약:"
    column -t -s',' "${summary}" 2>/dev/null || cat "${summary}"

    echo ""
    log "Cross-trial 통계 (IQR filtered, avg ± stddev):"
    column -t -s',' "${stats_iqr}" 2>/dev/null || cat "${stats_iqr}"

    echo ""

    # 히스토그램 (trial 1만)
    for sc in execve openat connect; do
        log "── ${sc} trial 1 히스토그램 ──"
        local f="${RESULT_HOST}/${LABEL}_${sc}_trial1.log"
        grep -A 30 '@latency:' "${f}" 2>/dev/null | head -25 || warn "없음"
        echo ""
    done

    log "결과: ${RESULT_HOST}/"
    log "완료 (label=${LABEL}, trials=${TRIALS}, reps=${LMBENCH_REPS}, openat_mult=${OPENAT_MULT}, pin_core=${PIN_CORE}, server=${SERVER_IP})"
}

# ── cleanup ──────────────────────────────────────────────────────────
do_cleanup() {
    log "정리"
    # 모든 정책 제거
    kubectl delete -f "${SCRIPT_DIR}/policies/kloudknox-policy.yaml" --ignore-not-found 2>/dev/null || true
    if helm status falco -n falco &>/dev/null; then
        helm upgrade falco falcosecurity/falco -n falco --reuse-values \
            --set-json 'customRules={}' --wait --timeout 120s 2>/dev/null || true
    fi
    kubectl delete -f "${SCRIPT_DIR}/policies/tetragon-policy.yaml" --ignore-not-found 2>/dev/null || true
    kubectl delete namespace "${NS}" --ignore-not-found --grace-period=5
    log "완료"
}

case "${1:-help}" in
    run)     do_run ;;
    deploy)  do_deploy ;;
    cleanup) do_cleanup ;;
    *)
        echo "사용법:"
        echo "  bash $0 run [vanilla|kloudknox|falco|tetragon]"
        echo "  bash $0 deploy"
        echo "  bash $0 cleanup"
        echo ""
        echo "환경변수:"
        echo "  TRIALS=5          반복 횟수 (기본 5)"
        echo "  WARMUP_SEC=30     워밍업 시간 (기본 30초)"
        echo "  LMBENCH_REPS=10   trial당 lmbench 반복 (기본 10회)"
        echo "  OPENAT_MULT=10    openat 추가 배수 (기본 10)"
        echo "  PIN_CORE=2        CPU pinning 코어 (기본 2)"
        ;;
esac
