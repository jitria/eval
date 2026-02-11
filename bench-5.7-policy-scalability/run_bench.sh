#!/usr/bin/env bash
###############################################################################
# run_bench.sh — 5.7 Policy Scalability (v3 - cross-node)
#
# 개선 사항 (v2 → v3):
#   - loopback 제거: 클라이언트(compute-node-1) → 서버(compute-node-2)
#     실제 네트워크 경로를 통해 connect → KloudKnox BPF 정책 룩업 실측
#   - 서버 Pod IP를 자동 감지하여 lat_connect에 전달
#
# 기존 유지 (v2):
#   1) lmbench lat_connect (5.5와 일관된 방법론)
#   2) comm 필터: "lat_connect"만 캡처
#   3) printf로 개별 ns 값 → p50/p99 오프라인 계산
#   4) 다중 trial + cross-trial avg/stddev
#   5) 워밍업, CPU pinning, IQR 필터링, drop_caches
#   6) kubectl cp 결과 전송
#
# 아키텍처:
#   compute-node-1 (클라이언트)
#   ├── bpftrace DaemonSet (privileged, hostPID)
#   │   └── trace_connect.bt (comm=="lat_connect" + printf)
#   └── workload Pod
#       └── lat_connect <서버PodIP>
#
#   compute-node-2 (서버)
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
NS="bench-policy"
RESULT_HOST="/tmp/2026SoCC/bench-5.7"
LABEL="${2:-vanilla}"
TRIALS="${TRIALS:-3}"
WARMUP_SEC="${WARMUP_SEC:-30}"
LMBENCH_REPS="${LMBENCH_REPS:-10}"
PIN_CORE="${PIN_CORE:-2}"
COOLDOWN="${COOLDOWN:-5}"
RULE_COUNTS="${RULE_COUNTS:-10 50 100 500 1000 5000}"

log()  { echo -e "\e[1;36m[5.7]\e[0m $*"; }
warn() { echo -e "\e[1;33m[5.7]\e[0m $*"; }

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

    echo "label,rule_count,trials,filter,avg_p50_ns,std_p50_ns,avg_p99_ns,std_p99_ns,avg_mean_ns,std_mean_ns,avg_count,std_count" > "${stats_csv}"

    for rc in ${RULE_COUNTS}; do
        grep "^${LABEL},${rc},[0-9]*,${filter}," "${summary_csv}" 2>/dev/null | awk -F',' \
            -v label="${LABEL}" -v rc="${rc}" -v filter="${filter}" '
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
                label, rc, n, filter,
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

    # 서버 Pod IP 가져오기
    SERVER_IP=$(kubectl -n "${NS}" get pod tcp-server -o jsonpath='{.status.podIP}')
    log "서버 Pod IP: ${SERVER_IP} (compute-node-2)"

    # 규칙 파일 생성
    log "규칙 세트 생성 (${LABEL})"
    mkdir -p "${RESULT_HOST}/rules"
    for count in ${RULE_COUNTS}; do
        case "${LABEL}" in
            kloudknox)
                python3 "${SCRIPT_DIR}/policies/generate_kloudknox_policies.py" \
                    --count "${count}" \
                    --namespace "${NS}" \
                    --output "${RESULT_HOST}/rules/kloudknox_${count}.yaml"
                ;;
            falco)
                python3 "${SCRIPT_DIR}/policies/generate_falco_rules.py" \
                    --count "${count}" \
                    --output "${RESULT_HOST}/rules/falco_${count}.yaml"
                ;;
            tetragon)
                python3 "${SCRIPT_DIR}/policies/generate_tetragon_policies.py" \
                    --count "${count}" \
                    --output "${RESULT_HOST}/rules/tetragon_${count}.yaml"
                ;;
            *)
                python3 "${SCRIPT_DIR}/generate_rules.py" \
                    --count "${count}" --type mixed \
                    --output "${RESULT_HOST}/rules/rules_${count}.json"
                ;;
        esac
    done

    log "Pod 배치 확인:"
    kubectl -n "${NS}" get pods -o wide

    # 바이너리 확인
    work_exec 'ls -la /tools/bin/lat_connect' || { warn "lat_connect 바이너리 없음"; return 1; }
    server_exec 'ls -la /tools/bin/bw_tcp' || { warn "bw_tcp 바이너리 없음"; return 1; }
    log "deploy 완료"
}

# ── trial 간 캐시 초기화 ─────────────────────────────────────────────
flush_caches() {
    log "캐시 초기화 (drop_caches + sync)"
    tracer_exec 'sync && echo 3 > /proc/sys/vm/drop_caches' || true
    sleep 5
}

# ── 정책 적용 검증 ─────────────────────────────────────────────────
verify_policy() {
    [[ "${LABEL}" == "vanilla" ]] && return
    log "  정책 적용 검증 (${LABEL})"
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
                    && log "    KloudKnox 에이전트 정책 로드 확인" \
                    || warn "    KloudKnox 에이전트 로그 확인 불가 (리소스는 존재)"
            else
                warn "  KloudKnox 정책 리소스 미생성"; return 1
            fi
            ;;
        falco)
            for _i in $(seq 1 30); do
                if kubectl logs -n falco -l app.kubernetes.io/name=falco -c falco --since=60s 2>/dev/null \
                    | grep -qi "Loading rules\|Loaded event"; then
                    ok=true; break
                fi
                sleep 2
            done
            [[ "${ok}" == "true" ]] && log "    Falco 룰 로딩 확인" \
                || { warn "  Falco 룰 로딩 미확인"; return 1; }
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
                    log "    TracingPolicy 센서 로드 확인"
                else
                    warn "    TracingPolicy 센서 로드 로그 미확인 (리소스는 존재)"
                fi
            else
                warn "  TracingPolicy 리소스 미생성"; return 1
            fi
            ;;
    esac
    log "  정책 검증 완료"
}

# ── 규칙 로드/언로드 ─────────────────────────────────────────────────
load_rules() {
    local count="$1"
    case "${LABEL}" in
        kloudknox)
            log "  KloudKnox: ${count} 규칙 로드"
            kubectl apply -f "${RESULT_HOST}/rules/kloudknox_${count}.yaml"
            ;;
        falco)
            log "  Falco: ${count} 규칙 로드 (helm upgrade)"
            helm upgrade falco falcosecurity/falco -n falco --reuse-values \
                --set-file "customRules.bench-rules\.yaml=${RESULT_HOST}/rules/falco_${count}.yaml" \
                --wait --timeout 120s
            ;;
        tetragon)
            log "  Tetragon: ${count} 규칙 로드"
            kubectl apply -f "${RESULT_HOST}/rules/tetragon_${count}.yaml"
            ;;
    esac
    verify_policy
}

unload_rules() {
    local count="$1"
    case "${LABEL}" in
        kloudknox)
            kubectl delete -f "${RESULT_HOST}/rules/kloudknox_${count}.yaml" --ignore-not-found 2>/dev/null || true
            sleep 2
            ;;
        falco)
            # 다음 load_rules에서 덮어쓰므로 별도 언로드 불필요
            ;;
        tetragon)
            kubectl delete -f "${RESULT_HOST}/rules/tetragon_${count}.yaml" --ignore-not-found 2>/dev/null || true
            sleep 2
            ;;
    esac
}

# ── 단일 측정 ────────────────────────────────────────────────────────
measure_one() {
    local rule_count="$1" trial="$2"
    local trace_file="/results/${LABEL}_rules${rule_count}_trial${trial}.log"

    # 1) bpftrace 시작 ("Attaching" 메시지로 attach 완료 확인)
    tracer_exec "
cat > /tmp/run_bt.sh << 'BTEOF'
#!/bin/bash
nohup bpftrace /scripts/trace_connect.bt > ${trace_file} 2>&1 &
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

    # 2) lat_connect → 서버 Pod IP (cross-node)
    log "  [rules=${rule_count}, trial ${trial}/${TRIALS}] lat_connect ${SERVER_IP} x${LMBENCH_REPS}"
    for i in $(seq 1 "${LMBENCH_REPS}"); do
        work_exec "${PIN_CMD} /tools/bin/lat_connect ${SERVER_IP} 2>/dev/null" || true
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

    # 시스템 정보
    tracer_exec "{ uname -a; lscpu | head -20; free -h; } > /results/${LABEL}_sysinfo.txt"

    # TCP 서버 시작 (서버 Pod, compute-node-2)
    log "TCP 서버 시작 (bw_tcp -s on ${SERVER_IP})"
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
    log "===== Warm-up (${WARMUP_SEC}초 동안 lat_connect ${SERVER_IP} 반복) ====="
    work_exec "
timeout ${WARMUP_SEC} bash -c '
while true; do
    ${PIN_CMD} /tools/bin/lat_connect ${SERVER_IP} >/dev/null 2>&1
done
' || true
echo 'warm-up done'
"
    log "Warm-up 완료"
    flush_caches

    # ── 결과 CSV 초기화 ──────────────────────────────────────────────
    local summary="${RESULT_HOST}/${LABEL}_summary.csv"
    echo "label,rule_count,trial,filter,avg_ns,p50_ns,p99_ns,min_ns,max_ns,count,stddev_ns" > "${summary}"

    # ── 측정 루프 ────────────────────────────────────────────────────
    for rule_count in ${RULE_COUNTS}; do
        log "===== 규칙 수: ${rule_count} ====="

        # 규칙 로드 (vanilla 제외)
        if [[ "${LABEL}" != "vanilla" ]]; then
            load_rules "${rule_count}"
        fi

        for trial in $(seq 1 "${TRIALS}"); do
            measure_one "${rule_count}" "${trial}"

            # 결과 전송
            local remote="/results/${LABEL}_rules${rule_count}_trial${trial}.log"
            local local_f="${RESULT_HOST}/${LABEL}_rules${rule_count}_trial${trial}.log"
            kubectl cp "${NS}/${TRACER_POD}:${remote}" "${local_f}" 2>/dev/null || \
                tracer_exec "cat ${remote}" > "${local_f}" 2>/dev/null || true

            # 파싱 + CSV
            if [[ -f "${local_f}" && -s "${local_f}" ]]; then
                local raw_stats iqr_stats
                raw_stats=$(compute_stats "${local_f}" "raw")
                iqr_stats=$(compute_stats "${local_f}" "iqr")
                echo "${LABEL},${rule_count},${trial},raw,${raw_stats}" >> "${summary}"
                echo "${LABEL},${rule_count},${trial},iqr,${iqr_stats}" >> "${summary}"

                # 화면에 요약 표시
                local p50 p99 cnt
                p50=$(echo "${iqr_stats}" | cut -d, -f2)
                p99=$(echo "${iqr_stats}" | cut -d, -f3)
                cnt=$(echo "${iqr_stats}" | cut -d, -f6)
                log "    rules=${rule_count} trial=${trial}: p50=${p50}ns  p99=${p99}ns  samples=${cnt}"
            else
                warn "    결과 파일 없음 또는 비어있음"
            fi

            # trial 간 쿨다운
            if [[ ${trial} -lt ${TRIALS} ]]; then
                sleep "${COOLDOWN}"
            fi
        done

        # 규칙 언로드 (vanilla 제외)
        if [[ "${LABEL}" != "vanilla" ]]; then
            unload_rules "${rule_count}"
        fi

        # rule_count 간 캐시 초기화
        flush_caches
    done

    # TCP 서버 종료
    server_exec 'pkill -f "bw_tcp" 2>/dev/null || true' || true

    # ── cross-trial 통계 ─────────────────────────────────────────────
    log "===== Cross-trial 통계 계산 ====="
    local stats_iqr="${RESULT_HOST}/${LABEL}_stats_iqr.csv"
    local stats_raw="${RESULT_HOST}/${LABEL}_stats_raw.csv"
    compute_cross_trial_stats "${summary}" "${stats_iqr}" "iqr"
    compute_cross_trial_stats "${summary}" "${stats_raw}" "raw"

    # ── 결과 표시 ────────────────────────────────────────────────────
    echo ""
    log "===== Per-trial 요약 ====="
    column -t -s',' "${summary}" 2>/dev/null || cat "${summary}"

    echo ""
    log "===== Cross-trial 통계 (IQR filtered, avg +/- stddev) ====="
    column -t -s',' "${stats_iqr}" 2>/dev/null || cat "${stats_iqr}"

    echo ""
    log "결과: ${RESULT_HOST}/"
    log "완료 (label=${LABEL}, trials=${TRIALS}, reps=${LMBENCH_REPS}, rule_counts=[${RULE_COUNTS}], pin_core=${PIN_CORE}, server=${SERVER_IP})"
}

# ── cleanup ──────────────────────────────────────────────────────────
do_cleanup() {
    log "전체 정리"
    kubectl delete namespace "${NS}" --ignore-not-found --grace-period=5
    log "정리 완료"
}

case "${1:-help}" in
    run)     do_run ;;
    deploy)  do_deploy ;;
    cleanup) do_cleanup ;;
    *)
        echo "사용법:"
        echo "  bash $0 run [vanilla|kloudknox|falco|tetragon]   # 전체 실행"
        echo "  bash $0 deploy                     # 인프라만 배포"
        echo "  bash $0 cleanup                    # 전체 정리"
        echo ""
        echo "환경변수:"
        echo "  TRIALS=3              반복 횟수 (기본 3)"
        echo "  WARMUP_SEC=30         워밍업 시간 (기본 30초)"
        echo "  LMBENCH_REPS=10       trial당 lmbench 반복 (기본 10회)"
        echo "  PIN_CORE=2            CPU pinning 코어 (기본 2)"
        echo "  COOLDOWN=5            trial 간 쿨다운 (기본 5초)"
        echo "  RULE_COUNTS='10 50 100 500 1000 5000'  규칙 수 리스트"
        ;;
esac
