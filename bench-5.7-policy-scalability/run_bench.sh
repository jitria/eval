#!/usr/bin/env bash
###############################################################################
# run_bench.sh — 5.7 Policy Scalability (v4 - 레이턴시 + 처리량 분리)
#
# 개선 사항 (v3 → v4):
#   - latency/throughput 모드 분리
#   - throughput: 규칙 수별 connect ops/sec 측정
#   - 인라인 stddev 표시
#
# 측정 모드:
#   latency    — bpftrace로 connect syscall ns 단위 지연시간 (규칙 수별)
#   throughput — lat_connect 반복 실행, 규칙 수별 ops/sec 측정
#
# 아키텍처:
#   compute-node-1 (클라이언트 + 서버, localhost)
#   ├── bpftrace DaemonSet (privileged, hostPID)
#   │   └── trace_connect.bt (comm=="lat_connect" + printf)
#   └── workload Pod
#       ├── bw_tcp -s (TCP accept 서버, localhost)
#       └── lat_connect 127.0.0.1
#
# 사용법:
#   bash run_bench.sh latency    [vanilla|kloudknox|falco|tetragon]
#   bash run_bench.sh throughput [vanilla|kloudknox|falco|tetragon]
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
TPUT_DURATION="${TPUT_DURATION:-10}"  # 처리량 측정 시간 (초, 외부 루프 미사용)
TPUT_N="${TPUT_N:-1000}"             # lat_connect -N 반복 횟수
RULE_COUNTS="${RULE_COUNTS:-10 50 100 500 1000 5000}"

log()  { echo -e "\e[1;36m[5.7]\e[0m $*"; }
warn() { echo -e "\e[1;33m[5.7]\e[0m $*"; }

TRACER_POD=""
WORKLOAD_POD="workload"
SERVER_IP="127.0.0.1"
PIN_CMD=""

get_tracer_pod() {
    kubectl -n "${NS}" get pods -l app=bpftrace-tracer \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

tracer_exec() { kubectl -n "${NS}" exec "${TRACER_POD}" -- bash -c "$1" 2>&1; }
work_exec()   { kubectl -n "${NS}" exec "${WORKLOAD_POD}" -- bash -c "$1" 2>&1; }

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

            printf "%.2f,%.2f,%.2f,%.2f,%.2f,%d,%.2f\n", avg/1000, fa[p50_idx]/1000, fa[p99_idx]/1000, fa[1]/1000, fa[fn]/1000, fn, stddev/1000
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

            printf "%.2f,%.2f,%.2f,%.2f,%.2f,%d,%.2f\n", avg/1000, a[p50_idx]/1000, a[p99_idx]/1000, a[1]/1000, a[n]/1000, n, stddev/1000
        }' "${sorted}"
    fi
}

# ── cross-trial 통계 계산 ────────────────────────────────────────────
compute_cross_trial_stats() {
    local summary_csv="$1" stats_csv="$2" filter="$3"

    echo "label,rule_count,trials,filter,avg_p50_us,std_p50_us,avg_p99_us,std_p99_us,avg_mean_us,std_mean_us,avg_count,std_count" > "${stats_csv}"

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

    log "DaemonSet 대기..."
    kubectl -n "${NS}" rollout status daemonset/bpftrace-tracer --timeout=120s
    log "workload Pod 대기..."
    kubectl -n "${NS}" wait --for=condition=Ready pod/workload --timeout=120s

    TRACER_POD=$(get_tracer_pod)
    log "bpftrace 설치 (${TRACER_POD})"
    tracer_exec 'apt-get update -qq && apt-get install -y -qq bpftrace >/dev/null 2>&1 && bpftrace --version'

    log "서버: localhost (127.0.0.1) — 네트워크 RTT 제거, 커널 오버헤드만 측정"

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
    work_exec 'ls -la /tools/bin/bw_tcp' || { warn "bw_tcp 바이너리 없음"; return 1; }
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
            for _i in $(seq 1 30); do
                if kubectl -n "${NS}" get kloudknoxpolicy.security.boanlab.com bench-scale-0000 2>/dev/null | grep -q "bench-scale"; then
                    ok=true; break
                fi
                sleep 1
            done
            if [[ "${ok}" == "true" ]]; then
                log "    KloudKnox 정책 리소스 확인 (bench-scale-0000 존재)"
                # agent가 정책을 로드할 시간 대기
                local kx_wait=$(( ${1:-10} / 10 ))
                [[ ${kx_wait} -lt 3 ]] && kx_wait=3
                [[ ${kx_wait} -gt 30 ]] && kx_wait=30
                sleep "${kx_wait}"
                kubectl logs -n kloudknox -l boanlab.com/app=kloudknox --tail=5 2>/dev/null \
                    | grep -qi "KloudKnoxPolicy" \
                    && log "    KloudKnox 에이전트 정책 로드 확인" \
                    || warn "    KloudKnox 에이전트 로그 확인 불가 (리소스는 존재)"
            else
                warn "  KloudKnox 정책 리소스 미생성"; return 1
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
            [[ "${ok}" == "true" ]] && log "    Falco 커스텀 룰 마운트 확인 (${fpod})" \
                || { warn "  Falco 룰 파일 미확인"; return 1; }
            ;;
        tetragon)
            # kubectl apply 직후 첫 번째 리소스 존재 확인 (전체 list 대신 단건 조회)
            for _i in $(seq 1 30); do
                if kubectl get tracingpolicy bench-scale-0000 2>/dev/null | grep -q "bench-scale"; then
                    ok=true; break
                fi
                sleep 1
            done
            if [[ "${ok}" == "true" ]]; then
                log "    TracingPolicy K8s 리소스 확인 (bench-scale-0000 존재)"

                # tetra tracingpolicy list로 센서 실제 로드 대기
                local tpod
                tpod=$(kubectl -n kube-system get pods -l app.kubernetes.io/name=tetragon \
                    --field-selector=status.phase=Running \
                    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
                if [[ -n "${tpod}" ]]; then
                    # 적용한 정책 수 (load_rules에서 넘긴 count)
                    local expect="${1:-0}"
                    for _i in $(seq 1 180); do
                        local loaded
                        loaded=$(kubectl -n kube-system exec "${tpod}" -c tetragon -- \
                            tetra tracingpolicy list 2>/dev/null | grep -c "enabled" || true)
                        loaded=${loaded:-0}
                        if [[ "${loaded}" -ge "${expect}" ]]; then
                            log "    Tetragon 센서 ${loaded}개 로드 완료"
                            break
                        fi
                        [[ $(( _i % 10 )) -eq 0 ]] && log "    센서 로드 중 (${loaded}/${expect})..."
                        sleep 2
                    done
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
    verify_policy "${count}"
}

unload_rules() {
    local count="$1"
    local wait_sec=$(( count > 100 ? 10 : 3 ))
    case "${LABEL}" in
        kloudknox)
            kubectl delete -f "${RESULT_HOST}/rules/kloudknox_${count}.yaml" --ignore-not-found 2>/dev/null || true
            # 리소스 제거 확인 (단건 조회)
            for _i in $(seq 1 60); do
                if ! kubectl -n "${NS}" get kloudknoxpolicy.security.boanlab.com bench-scale-0000 2>/dev/null | grep -q "bench-scale"; then
                    break
                fi
                sleep 2
            done
            ;;
        falco)
            # 다음 load_rules에서 덮어쓰므로 별도 언로드 불필요
            ;;
        tetragon)
            kubectl delete -f "${RESULT_HOST}/rules/tetragon_${count}.yaml" --ignore-not-found 2>/dev/null || true
            sleep "${wait_sec}"

            # 1) K8s 리소스 제거 확인 (단건 조회로 확인)
            for _i in $(seq 1 60); do
                if ! kubectl get tracingpolicy bench-scale-0000 2>/dev/null | grep -q "bench-scale"; then
                    break
                fi
                log "  K8s TracingPolicy 제거 대기..."
                sleep 2
            done

            # 2) Tetragon 내부 센서 제거 확인 (tetra tracingpolicy list)
            local tpod
            tpod=$(kubectl -n kube-system get pods -l app.kubernetes.io/name=tetragon \
                --field-selector=status.phase=Running \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
            if [[ -n "${tpod}" ]]; then
                for _i in $(seq 1 60); do
                    local sensor_count
                    sensor_count=$(kubectl -n kube-system exec "${tpod}" -c tetragon -- \
                        tetra tracingpolicy list 2>/dev/null | grep -c "bench-scale" || true)
                    sensor_count=${sensor_count:-0}
                    [[ "${sensor_count}" -eq 0 ]] && break
                    log "  Tetragon 센서 언로드 대기 (남은: ${sensor_count})..."
                    sleep 3
                done
            fi
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

# ── 공통 setup ───────────────────────────────────────────────────────
do_setup() {
    do_deploy
    TRACER_POD=$(get_tracer_pod)
    mkdir -p "${RESULT_HOST}"

    setup_cpu_pin
    tracer_exec "{ uname -a; lscpu | head -20; free -h; } > /results/${LABEL}_sysinfo.txt"

    log "TCP 서버 시작 (bw_tcp -s on localhost)"
    work_exec 'pkill -x bw_tcp 2>/dev/null || true' || true
    work_exec 'nohup /tools/bin/bw_tcp -s >/dev/null 2>&1 &'
    sleep 2

    log "서버 연결 확인 (${SERVER_IP})..."
    local connected=false
    for i in $(seq 1 30); do
        if work_exec "${PIN_CMD} /tools/bin/lat_connect ${SERVER_IP} 2>/dev/null" &>/dev/null; then
            connected=true; break
        fi
        sleep 1
    done
    if [[ "${connected}" != "true" ]]; then
        warn "서버 연결 실패 (${SERVER_IP}, 30초 타임아웃)"; return 1
    fi
    log "서버 연결 확인 완료 (localhost)"

    log "===== Warm-up (${WARMUP_SEC}초) ====="
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
}

# ── 처리량 cross-trial 통계 ──────────────────────────────────────────
compute_throughput_cross_trial_stats() {
    local summary_csv="$1" stats_csv="$2"

    echo "label,rule_count,trials,avg_ops_sec,std_ops_sec,avg_latency_us,std_latency_us" > "${stats_csv}"

    for rc in ${RULE_COUNTS}; do
        grep "^${LABEL},${rc},[0-9]*," "${summary_csv}" 2>/dev/null | awk -F',' \
            -v label="${LABEL}" -v rc="${rc}" '
        {
            n++
            sops += $4; sqops += $4*$4
            slat += $5; sqlat += $5*$5
        }
        END {
            if (n == 0) exit
            aops = sops/n; alat = slat/n
            vops = sqops/n - aops*aops; sdops = sqrt(vops > 0 ? vops : 0)
            vlat = sqlat/n - alat*alat; sdlat = sqrt(vlat > 0 ? vlat : 0)
            printf "%s,%s,%d,%.1f,%.1f,%.2f,%.2f\n", label, rc, n, aops, sdops, alat, sdlat
        }' >> "${stats_csv}" || true
    done
}

# ── latency (bpftrace로 connect ns 지연 측정, 규칙 수별) ──────────────
do_latency() {
    do_setup

    local summary="${RESULT_HOST}/${LABEL}_latency.csv"
    echo "label,rule_count,trial,filter,avg_us,p50_us,p99_us,min_us,max_us,count,stddev_us" > "${summary}"

    for rule_count in ${RULE_COUNTS}; do
        log "===== [Latency] 규칙 수: ${rule_count} ====="
        [[ "${LABEL}" != "vanilla" ]] && load_rules "${rule_count}"

        for trial in $(seq 1 "${TRIALS}"); do
            measure_one "${rule_count}" "${trial}"

            local remote="/results/${LABEL}_rules${rule_count}_trial${trial}.log"
            local local_f="${RESULT_HOST}/${LABEL}_rules${rule_count}_trial${trial}.log"
            kubectl cp "${NS}/${TRACER_POD}:${remote}" "${local_f}" 2>/dev/null || \
                tracer_exec "cat ${remote}" > "${local_f}" 2>/dev/null || true

            if [[ -f "${local_f}" && -s "${local_f}" ]]; then
                local raw_stats iqr_stats
                raw_stats=$(compute_stats "${local_f}" "raw")
                iqr_stats=$(compute_stats "${local_f}" "iqr")
                echo "${LABEL},${rule_count},${trial},raw,${raw_stats}" >> "${summary}"
                echo "${LABEL},${rule_count},${trial},iqr,${iqr_stats}" >> "${summary}"

                local i_avg i_p50 i_p99 i_cnt i_sd
                i_avg=$(echo "${iqr_stats}" | cut -d, -f1)
                i_p50=$(echo "${iqr_stats}" | cut -d, -f2)
                i_p99=$(echo "${iqr_stats}" | cut -d, -f3)
                i_cnt=$(echo "${iqr_stats}" | cut -d, -f6)
                i_sd=$(echo "${iqr_stats}"  | cut -d, -f7)
                log "    rules=${rule_count} trial=${trial}: avg=${i_avg}±${i_sd}μs  p50=${i_p50}μs  p99=${i_p99}μs  (n=${i_cnt})"
            else
                warn "    결과 없음"
            fi

            [[ ${trial} -lt ${TRIALS} ]] && sleep "${COOLDOWN}"
        done

        [[ "${LABEL}" != "vanilla" ]] && unload_rules "${rule_count}"
        flush_caches
    done

    work_exec 'pkill -x bw_tcp 2>/dev/null || true' || true

    log "===== Latency Cross-trial 통계 ====="
    local stats_iqr="${RESULT_HOST}/${LABEL}_latency_stats_iqr.csv"
    local stats_raw="${RESULT_HOST}/${LABEL}_latency_stats_raw.csv"
    compute_cross_trial_stats "${summary}" "${stats_iqr}" "iqr"
    compute_cross_trial_stats "${summary}" "${stats_raw}" "raw"

    echo ""
    log "Per-trial:"
    column -t -s',' "${summary}" 2>/dev/null || cat "${summary}"
    echo ""
    log "Cross-trial (IQR, avg ± stddev):"
    column -t -s',' "${stats_iqr}" 2>/dev/null || cat "${stats_iqr}"
    echo ""
    log "완료 (mode=latency, label=${LABEL}, trials=${TRIALS}, reps=${LMBENCH_REPS}, rules=[${RULE_COUNTS}])"
}

# ── throughput (규칙 수별 connect ops/sec 측정) ───────────────────────
# lat_connect -N 으로 내부 반복, 출력된 μs 값에서 ops/sec = 1000000/μs 계산
do_throughput() {
    do_setup

    local summary="${RESULT_HOST}/${LABEL}_throughput.csv"
    echo "label,rule_count,trial,ops_sec,latency_us,N" > "${summary}"

    for rule_count in ${RULE_COUNTS}; do
        log "===== [Throughput] 규칙 수: ${rule_count} ====="

        # bw_tcp 서버 재시작 (대량 연결 후 크래시 방지)
        work_exec 'pkill -x bw_tcp 2>/dev/null || true' || true
        sleep 1
        work_exec 'nohup /tools/bin/bw_tcp -s >/dev/null 2>&1 &'
        sleep 1

        # bw_tcp 재시작 후 워밍업 (Trial 1 아웃라이어 방지)
        work_exec "${PIN_CMD} /tools/bin/lat_connect -N 200 ${SERVER_IP} >/dev/null 2>&1" || true
        sleep 1

        [[ "${LABEL}" != "vanilla" ]] && load_rules "${rule_count}"

        for trial in $(seq 1 "${TRIALS}"); do
            log "  rules=${rule_count} trial=${trial}: lat_connect -N ${TPUT_N}"

            local result
            result=$(work_exec "${PIN_CMD} /tools/bin/lat_connect -N ${TPUT_N} ${SERVER_IP} 2>&1")

            # "TCP/IP connection cost to X.X.X.X: 123.4567 microseconds" 파싱
            local latency_us ops_sec
            latency_us=$(echo "${result}" | grep -oP '[\d.]+(?= microseconds)' | head -1)

            if [[ -n "${latency_us}" ]]; then
                ops_sec=$(awk "BEGIN {printf \"%.1f\", 1000000 / ${latency_us}}")
                echo "${LABEL},${rule_count},${trial},${ops_sec},${latency_us},${TPUT_N}" >> "${summary}"
                log "    latency=${latency_us}μs  ops/sec=${ops_sec}  (N=${TPUT_N})"
            else
                warn "    측정 실패: ${result}"
                echo "${LABEL},${rule_count},${trial},0,0,${TPUT_N}" >> "${summary}"
            fi

            [[ ${trial} -lt ${TRIALS} ]] && sleep "${COOLDOWN}"
        done

        [[ "${LABEL}" != "vanilla" ]] && unload_rules "${rule_count}"
        flush_caches
    done

    work_exec 'pkill -x bw_tcp 2>/dev/null || true' || true

    log "===== Throughput Cross-trial 통계 ====="
    local stats_csv="${RESULT_HOST}/${LABEL}_throughput_stats.csv"
    compute_throughput_cross_trial_stats "${summary}" "${stats_csv}"

    echo ""
    log "Per-trial:"
    column -t -s',' "${summary}" 2>/dev/null || cat "${summary}"
    echo ""
    log "Cross-trial (avg ± stddev):"
    column -t -s',' "${stats_csv}" 2>/dev/null || cat "${stats_csv}"
    echo ""
    log "완료 (mode=throughput, label=${LABEL}, trials=${TRIALS}, N=${TPUT_N}, rules=[${RULE_COUNTS}])"
}

# ── cleanup ──────────────────────────────────────────────────────────
do_cleanup() {
    log "전체 정리"
    # 모든 정책 제거
    kubectl delete kloudknoxpolicy.security.boanlab.com --all -n "${NS}" --ignore-not-found 2>/dev/null || true
    if helm status falco -n falco &>/dev/null; then
        helm upgrade falco falcosecurity/falco -n falco --reuse-values \
            --set-json 'customRules={}' --wait --timeout 120s 2>/dev/null || true
    fi
    kubectl delete tracingpolicy --all --ignore-not-found 2>/dev/null || true
    kubectl delete namespace "${NS}" --ignore-not-found --grace-period=5
    log "정리 완료"
}

case "${1:-help}" in
    latency)    do_latency ;;
    throughput) do_throughput ;;
    deploy)     do_deploy ;;
    cleanup)    do_cleanup ;;
    *)
        echo "사용법:"
        echo "  bash $0 latency    [vanilla|kloudknox|falco|tetragon]  # 지연시간 측정 (bpftrace)"
        echo "  bash $0 throughput [vanilla|kloudknox|falco|tetragon]  # 처리량(ops/sec) 측정"
        echo "  bash $0 deploy                                         # 인프라만 배포"
        echo "  bash $0 cleanup                                        # 전체 정리"
        echo ""
        echo "환경변수:"
        echo "  TRIALS=3              반복 횟수 (기본 3)"
        echo "  WARMUP_SEC=30         워밍업 시간 (기본 30초)"
        echo "  LMBENCH_REPS=10       trial당 lmbench 반복 (기본 10회)"
        echo "  PIN_CORE=2            CPU pinning 코어 (기본 2)"
        echo "  COOLDOWN=5            trial 간 쿨다운 (기본 5초)"
        echo "  TPUT_DURATION=10      처리량 측정 시간 (기본 10초)"
        echo "  RULE_COUNTS='10 50 100 500 1000 5000'  규칙 수 리스트"
        ;;
esac
