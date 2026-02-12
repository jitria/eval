#!/usr/bin/env bash
###############################################################################
# run_bench.sh — 5.7 Policy Scalability
#
# 아키텍처:
#   boar (클라이언트)
#   ├── monitor DaemonSet (privileged, hostPID) — 에이전트/노드 리소스 샘플링
#   └── ab-client Pod — ab 실행
#   camel (서버)
#   └── Nginx Deployment — HTTP 서버
#
# 사용법:
#   bash run_bench.sh run     [kloudknox|falco|tetragon]
#   bash run_bench.sh deploy
#   bash run_bench.sh cleanup
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NS="bench-policy"
LABEL="${2:-vanilla}"
RESULT_HOST="$(dirname "${SCRIPT_DIR}")/result/5.7/${LABEL}"
TRIALS="${TRIALS:-3}"
COOLDOWN="${COOLDOWN:-5}"
RULE_COUNTS="${RULE_COUNTS:-1 3 7 10}"
CONCURRENCY_LEVELS="${CONCURRENCY_LEVELS:-1 5 10 50 100}"
BENCH_DURATION="${BENCH_DURATION:-10}"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-1}"
WARMUP_REQUESTS="${WARMUP_REQUESTS:-1000}"

# 에이전트 이름 매핑 (vanilla이면 빈 문자열 → 모니터링 스킵)
case "${LABEL}" in
    kloudknox) AGENT_NAME="kloudknox" ;;
    falco)     AGENT_NAME="falco" ;;
    tetragon)  AGENT_NAME="tetragon" ;;
    *)         AGENT_NAME="" ;;
esac

log()  { echo -e "\e[1;36m[5.7]\e[0m $*"; }
warn() { echo -e "\e[1;33m[5.7]\e[0m $*"; }

TRACER_POD=""
AB_POD="ab-client"
SERVER_URL="http://nginx-svc.bench-policy.svc.cluster.local:80/"

get_tracer_pod() {
    kubectl -n "${NS}" get pods -l app=bpftrace-tracer \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

tracer_exec() { kubectl -n "${NS}" exec "${TRACER_POD}" -- bash -c "$1" 2>&1; }
ab_exec()     { kubectl -n "${NS}" exec "${AB_POD}" -- bash -c "ulimit -n 65535; $1" 2>&1; }

# ── ab 출력 파싱 ──────────────────────────────────────────────────────
# 출력: total_reqs,rps,mean_us,p50_us,p90_us,p95_us,p99_us,max_us,failed,transfer_kbps
# ab는 ms 단위 → μs 변환 (x1000)
parse_ab_result() {
    local file="$1"

    if [[ ! -f "${file}" ]] || [[ ! -s "${file}" ]]; then
        echo "0,0,0,0,0,0,0,0,0,0"
        return
    fi

    awk '
    /^Complete requests:/ { total_reqs = $3 }
    /^Failed requests:/   { failed = $3 }
    /^Requests per second:/ { rps = $4 }
    /^Time per request:/ && !mean_set {
        mean_ms = $4
        mean_set = 1
    }
    /^Transfer rate:/ { transfer_kbps = $3 }
    /^ *50%/ { p50 = $2 }
    /^ *90%/ { p90 = $2 }
    /^ *95%/ { p95 = $2 }
    /^ *99%/ { p99 = $2 }
    /^ *100%/ { max = $2 }
    END {
        printf "%d,%.2f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%d,%.2f\n",
            total_reqs+0, rps+0, mean_ms*1000,
            p50*1000, p90*1000, p95*1000, p99*1000, max*1000,
            failed+0, transfer_kbps+0
    }
    ' "${file}"
}

# ── cross-trial 통계 계산 ────────────────────────────────────────────
compute_cross_trial_stats() {
    local summary_csv="$1" stats_csv="$2"

    echo "label,concurrency,rule_count,trials,avg_rps,std_rps,avg_mean_us,std_mean_us,avg_p50_us,std_p50_us,avg_p99_us,std_p99_us,avg_max_us,std_max_us" > "${stats_csv}"

    for conc in ${CONCURRENCY_LEVELS}; do
        for rc in ${RULE_COUNTS}; do
            grep "^${LABEL},${conc},${rc}," "${summary_csv}" 2>/dev/null | awk -F',' \
                -v label="${LABEL}" -v conc="${conc}" -v rc="${rc}" '
            {
                n++
                srps  += $6;  sqrps  += $6*$6
                smean += $7;  sqmean += $7*$7
                sp50  += $8;  sqp50  += $8*$8
                sp99  += $11; sqp99  += $11*$11
                smax  += $12; sqmax  += $12*$12
            }
            END {
                if (n == 0) exit
                arps  = srps/n;  amean = smean/n
                ap50  = sp50/n;  ap99  = sp99/n;  amax = smax/n

                vrps  = sqrps/n  - arps*arps;   sdrps  = sqrt(vrps  > 0 ? vrps  : 0)
                vmean = sqmean/n - amean*amean;  sdmean = sqrt(vmean > 0 ? vmean : 0)
                vp50  = sqp50/n  - ap50*ap50;    sdp50  = sqrt(vp50  > 0 ? vp50  : 0)
                vp99  = sqp99/n  - ap99*ap99;    sdp99  = sqrt(vp99  > 0 ? vp99  : 0)
                vmax  = sqmax/n  - amax*amax;    sdmax  = sqrt(vmax  > 0 ? vmax  : 0)

                printf "%s,%s,%s,%d,%.2f,%.2f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f\n",
                    label, conc, rc, n,
                    arps, sdrps, amean, sdmean,
                    ap50, sdp50, ap99, sdp99,
                    amax, sdmax
            }' >> "${stats_csv}" || true
        done
    done
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
            for _i in $(seq 1 30); do
                if kubectl get tracingpolicy bench-scale-0000 2>/dev/null | grep -q "bench-scale"; then
                    ok=true; break
                fi
                sleep 1
            done
            if [[ "${ok}" == "true" ]]; then
                log "    TracingPolicy K8s 리소스 확인 (bench-scale-0000 존재)"

                local tpod
                tpod=$(kubectl -n kube-system get pods -l app.kubernetes.io/name=tetragon \
                    --field-selector=status.phase=Running \
                    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
                if [[ -n "${tpod}" ]]; then
                    local expect="${1:-0}"
                    for _i in $(seq 1 180); do
                        local loaded
                        loaded=$(kubectl -n kube-system exec "${tpod}" -c tetragon -- \
                            tetra tracingpolicy list 2>/dev/null | grep -c "bench-scale" || true)
                        loaded=${loaded:-0}
                        if [[ "${loaded}" -ge "${expect}" ]]; then
                            log "    Tetragon bench-scale 센서 ${loaded}/${expect}개 로드 완료"
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

            for _i in $(seq 1 60); do
                if ! kubectl get tracingpolicy bench-scale-0000 2>/dev/null | grep -q "bench-scale"; then
                    break
                fi
                log "  K8s TracingPolicy 제거 대기..."
                sleep 2
            done

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

# ── 에이전트 리소스 모니터링 ───────────────────────────────────────────
start_monitor() {
    local rule_count="$1" trial="$2" conc="$3"
    [[ -z "${AGENT_NAME}" ]] && return 0

    local csv="/results/${LABEL}_resource_c${conc}_rules${rule_count}_trial${trial}.csv"
    log "    모니터링 시작 (agent=${AGENT_NAME}, c=${conc}, rules=${rule_count}, trial=${trial})"
    tracer_exec "
nohup bash /scripts/monitor_agent.sh '${AGENT_NAME}' '${MONITOR_INTERVAL}' '${rule_count}' '${csv}' >/dev/null 2>&1 &
echo \$! > /tmp/mon_pid
" || warn "    모니터링 시작 실패"
}

stop_monitor() {
    local rule_count="$1" trial="$2" conc="$3"
    [[ -z "${AGENT_NAME}" ]] && return 0

    local csv="/results/${LABEL}_resource_c${conc}_rules${rule_count}_trial${trial}.csv"
    local local_csv="${RESULT_HOST}/${LABEL}_resource_c${conc}_rules${rule_count}_trial${trial}.csv"

    log "    모니터링 중지 (c=${conc}, rules=${rule_count}, trial=${trial})"
    tracer_exec '
MON_PID=$(cat /tmp/mon_pid 2>/dev/null)
if [ -n "${MON_PID}" ] && kill -0 ${MON_PID} 2>/dev/null; then
    kill -TERM ${MON_PID} 2>/dev/null || true
    sleep 2
fi
' || true

    kubectl cp "${NS}/${TRACER_POD}:${csv}" "${local_csv}" 2>/dev/null || \
        tracer_exec "cat ${csv}" > "${local_csv}" 2>/dev/null || true

    if [[ -f "${local_csv}" && -s "${local_csv}" ]]; then
        local samples
        samples=$(( $(wc -l < "${local_csv}") - 1 ))
        log "      리소스 샘플 ${samples}개 수집"
    else
        warn "      리소스 데이터 없음"
    fi
}

compute_resource_summary() {
    [[ -z "${AGENT_NAME}" ]] && return 0

    local out="${RESULT_HOST}/${LABEL}_resource.csv"
<<<<<<< HEAD
    echo "label,rule_count,avg_agent_cpu,std_agent_cpu,avg_agent_mem,std_agent_mem,avg_node_cpu,std_node_cpu,avg_node_sys,std_node_sys,samples" > "${out}"
=======
    echo "label,concurrency,rule_count,avg_agent_cpu,std_agent_cpu,avg_agent_mem,std_agent_mem,avg_node_cpu,std_node_cpu,avg_node_mem,std_node_mem,samples" > "${out}"
>>>>>>> e095930 (Update raw data)

    for conc in ${CONCURRENCY_LEVELS}; do
        for rc in ${RULE_COUNTS}; do
            local merged=""
            for t in $(seq 1 "${TRIALS}"); do
                local raw="${RESULT_HOST}/${LABEL}_resource_c${conc}_rules${rc}_trial${t}.csv"
                [[ -f "${raw}" && -s "${raw}" ]] && merged="${merged} ${raw}"
            done
            [[ -z "${merged}" ]] && continue

            awk -F',' -v label="${LABEL}" -v conc="${conc}" -v rc="${rc}" '
            FNR > 1 && NF >= 7 {
                n++
                sc += $3; sqc += $3*$3
                sm += $4; sqm += $4*$4
                snc += $5; sqnc += $5*$5
                snm += $6; sqnm += $6*$6
            }
            END {
                if (n == 0) exit
                ac = sc/n; am = sm/n; anc = snc/n; anm = snm/n
                vc = sqc/n - ac*ac; sdc = sqrt(vc > 0 ? vc : 0)
                vm = sqm/n - am*am; sdm = sqrt(vm > 0 ? vm : 0)
                vnc = sqnc/n - anc*anc; sdnc = sqrt(vnc > 0 ? vnc : 0)
                vnm = sqnm/n - anm*anm; sdnm = sqrt(vnm > 0 ? vnm : 0)
                printf "%s,%s,%s,%.2f,%.2f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%d\n",
                    label, conc, rc, ac, sdc, am, sdm, anc, sdnc, anm, sdnm, n
            }' ${merged} >> "${out}" || true
        done
<<<<<<< HEAD
        [[ -z "${merged}" ]] && continue

        awk -F',' -v label="${LABEL}" -v rc="${rc}" '
        FNR > 1 && NF >= 6 {
            n++
            sc += $3; sqc += $3*$3
            sm += $4; sqm += $4*$4
            snc += $5; sqnc += $5*$5
            sns += $6; sqns += $6*$6
        }
        END {
            if (n == 0) exit
            ac = sc/n; am = sm/n; anc = snc/n; ans = sns/n
            vc = sqc/n - ac*ac; sdc = sqrt(vc > 0 ? vc : 0)
            vm = sqm/n - am*am; sdm = sqrt(vm > 0 ? vm : 0)
            vnc = sqnc/n - anc*anc; sdnc = sqrt(vnc > 0 ? vnc : 0)
            vns = sqns/n - ans*ans; sdns = sqrt(vns > 0 ? vns : 0)
            printf "%s,%s,%.2f,%.2f,%.1f,%.1f,%.2f,%.2f,%.2f,%.2f,%d\n",
                label, rc, ac, sdc, am, sdm, anc, sdnc, ans, sdns, n
        }' ${merged} >> "${out}" || true
=======
>>>>>>> e095930 (Update raw data)
    done

    log "===== 에이전트 리소스 요약 ====="
    column -t -s',' "${out}" 2>/dev/null || cat "${out}"
}

# ── deploy ───────────────────────────────────────────────────────────
do_deploy() {
    log "배포 시작"
    kubectl apply -f "${SCRIPT_DIR}/00-namespace.yaml"
    kubectl apply -f "${SCRIPT_DIR}/01-bpftrace-daemonset.yaml"
    kubectl apply -f "${SCRIPT_DIR}/nginx-configmap.yaml"
    kubectl apply -f "${SCRIPT_DIR}/02-nginx-deployment.yaml"
    kubectl apply -f "${SCRIPT_DIR}/03-ab-client-pod.yaml"

    log "DaemonSet 대기..."
    kubectl -n "${NS}" rollout status daemonset/bpftrace-tracer --timeout=120s
    log "Nginx 대기..."
    kubectl -n "${NS}" rollout status deployment/nginx --timeout=120s
    log "ab-client Pod 대기..."
    kubectl -n "${NS}" wait --for=condition=Ready pod/${AB_POD} --timeout=120s

    TRACER_POD=$(get_tracer_pod)
    log "모니터링 도구 설치 (${TRACER_POD})"
    tracer_exec 'apt-get update -qq && apt-get install -y -qq procps >/dev/null 2>&1'

    log "ab 설치 확인..."
    if ! ab_exec 'which ab' &>/dev/null; then
        log "ab 설치 중 (apache2-utils)..."
        ab_exec 'apt-get update -qq && apt-get install -y -qq apache2-utils > /dev/null 2>&1'
    fi
    ab_exec 'ab -V | head -1'

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
        esac
    done

    log "Pod 배치 확인:"
    kubectl -n "${NS}" get pods -o wide
    log "deploy 완료"
}

# ── 공통 setup (deploy + 연결확인 + 워밍업) ─────────────────────────
do_setup() {
    do_deploy
    TRACER_POD=$(get_tracer_pod)
    mkdir -p "${RESULT_HOST}"

    tracer_exec "{ uname -a; lscpu | head -20; free -h; } > /results/${LABEL}_sysinfo.txt"

    log "서버 연결 확인..."
    local connected=false
    for i in $(seq 1 30); do
        if ab_exec "ab -n 1 -c 1 ${SERVER_URL}" &>/dev/null; then
            connected=true; break
        fi
        sleep 1
    done
    if [[ "${connected}" != "true" ]]; then
        warn "서버 연결 실패 (30초 타임아웃)"; return 1
    fi
    log "서버 연결 확인 완료"

    local max_conc
    max_conc=$(echo ${CONCURRENCY_LEVELS} | tr ' ' '\n' | sort -n | tail -1)
    log "===== Warm-up (c=${max_conc}, ${WARMUP_REQUESTS} requests) ====="
    ab_exec "ab -n ${WARMUP_REQUESTS} -c ${max_conc} ${SERVER_URL} > /dev/null 2>&1" || true
    log "Warm-up 완료"
    sleep 3
    flush_caches
}

# ── run (ab 측정, 규칙 수 × 동시 연결 수별) ──────────────────────────
do_run() {
    do_setup

    local summary="${RESULT_HOST}/${LABEL}_ab_summary.csv"
    echo "label,concurrency,rule_count,trial,total_reqs,rps,mean_us,p50_us,p90_us,p95_us,p99_us,max_us,failed,transfer_kbps" > "${summary}"

    for rule_count in ${RULE_COUNTS}; do
        log "===== 규칙 수: ${rule_count} ====="
        [[ "${LABEL}" != "vanilla" ]] && load_rules "${rule_count}"

        for conc in ${CONCURRENCY_LEVELS}; do
            log "  --- c=${conc}, rules=${rule_count}, duration=${BENCH_DURATION}s ---"

            for trial in $(seq 1 "${TRIALS}"); do
                local tag="ab_c${conc}_rules${rule_count}_trial${trial}"
                local remote="/results/${LABEL}_${tag}.txt"
                local local_f="${RESULT_HOST}/${LABEL}_${tag}.txt"

                start_monitor "${rule_count}" "${trial}" "${conc}"

                log "  [c=${conc}, rules=${rule_count}, trial ${trial}/${TRIALS}] ab -t ${BENCH_DURATION} -c ${conc}"
                ab_exec "ab -n 9999999 -t ${BENCH_DURATION} -c ${conc} ${SERVER_URL} > ${remote} 2>&1" || true

                stop_monitor "${rule_count}" "${trial}" "${conc}"

                # 결과 복사 + 파싱
                kubectl cp "${NS}/${AB_POD}:${remote}" "${local_f}" 2>/dev/null || \
                    ab_exec "cat ${remote}" > "${local_f}" 2>/dev/null || true

                if [[ -f "${local_f}" && -s "${local_f}" ]]; then
                    local stats
                    stats=$(parse_ab_result "${local_f}")
                    echo "${LABEL},${conc},${rule_count},${trial},${stats}" >> "${summary}"

                    local rps_d mean_d p50_d p99_d failed_d
                    rps_d=$(echo "${stats}" | cut -d, -f2)
                    mean_d=$(echo "${stats}" | cut -d, -f3)
                    p50_d=$(echo "${stats}" | cut -d, -f4)
                    p99_d=$(echo "${stats}" | cut -d, -f7)
                    failed_d=$(echo "${stats}" | cut -d, -f9)
                    log "    RPS=${rps_d}  mean=${mean_d}μs  p50=${p50_d}μs  p99=${p99_d}μs  failed=${failed_d}"
                else
                    warn "    결과 없음"
                fi

                [[ ${trial} -lt ${TRIALS} ]] && sleep "${COOLDOWN}"
            done

            sleep "${COOLDOWN}"
        done

        [[ "${LABEL}" != "vanilla" ]] && unload_rules "${rule_count}"
        flush_caches
    done

    compute_resource_summary

    log "===== Cross-trial 통계 ====="
    local stats_csv="${RESULT_HOST}/${LABEL}_ab_stats.csv"
    compute_cross_trial_stats "${summary}" "${stats_csv}"

    echo ""
    log "Per-trial:"
    column -t -s',' "${summary}" 2>/dev/null || cat "${summary}"
    echo ""
    log "Cross-trial (avg +/- stddev):"
    column -t -s',' "${stats_csv}" 2>/dev/null || cat "${stats_csv}"
    echo ""
    log "완료 (label=${LABEL}, trials=${TRIALS}, duration=${BENCH_DURATION}s, c=[${CONCURRENCY_LEVELS}], rules=[${RULE_COUNTS}])"
}

# ── cleanup ──────────────────────────────────────────────────────────
do_cleanup() {
    log "전체 정리"
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
    run)        do_run ;;
    deploy)     do_deploy ;;
    cleanup)    do_cleanup ;;
    *)
        echo "사용법:"
        echo "  bash $0 run     [kloudknox|falco|tetragon]  # 벤치마크 실행"
        echo "  bash $0 deploy                               # 인프라 배포"
        echo "  bash $0 cleanup                              # 전체 정리"
        echo ""
        echo "환경변수:"
        echo "  TRIALS=3                         반복 횟수 (기본 3)"
        echo "  BENCH_DURATION=10                ab 실행 시간 초 (기본 10)"
        echo "  CONCURRENCY_LEVELS='1 5 10 50 100'  동시 연결 수 리스트"
        echo "  COOLDOWN=5                       trial 간 쿨다운 초 (기본 5)"
        echo "  WARMUP_REQUESTS=1000             워밍업 요청 수 (기본 1000)"
        echo "  MONITOR_INTERVAL=1               리소스 샘플링 간격 초 (기본 1)"
        echo "  RULE_COUNTS='1 3 7 10'           규칙 수 리스트"
        ;;
esac
