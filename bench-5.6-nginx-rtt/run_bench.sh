#!/usr/bin/env bash
###############################################################################
# run_bench.sh — 5.6 Nginx RTT (v3 - 레이턴시 + 처리량)
#
# 개선 사항 (v2 → v3):
#   1) 처리량(Max RPS) 측정 추가: wrk closed-loop 모드
#   2) 인라인 stddev 표시: per-trial 즉시 avg±stddev 출력
#   3) 처리량 cross-trial avg±stddev
#
# 측정 모드:
#   Phase 1 — 레이턴시: wrk2 -R (constant throughput, 고정 RPS에서 지연 측정)
#   Phase 2 — 처리량:  wrk (closed-loop, 커넥션별 최대 RPS 측정)
#
# 아키텍처:
#   Nginx (compute-node-2, Deployment + NodePort 30080)
#     ← wrk2 (compute-node-1, Pod + kubectl exec)
#   ClusterIP Service 통한 HTTP 접속
#
# 사용법:
#   bash run_bench.sh run   [vanilla|kloudknox|falco|tetragon]
#   bash run_bench.sh deploy
#   bash run_bench.sh cleanup
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NS="bench-nginx"
RESULT_HOST="/tmp/2026SoCC/bench-5.6"
LABEL="${2:-vanilla}"
TRIALS="${TRIALS:-3}"
WARMUP_SEC="${WARMUP_SEC:-10}"
DURATION="${DURATION:-60s}"
THREADS="${THREADS:-4}"
COOLDOWN="${COOLDOWN:-10}"
RPS_LIST="${RPS_LIST:-1000 5000 10000}"
CONN_LIST="${CONN_LIST:-10 50 100 500 1000}"

SERVER_URL="http://nginx-bench-svc.bench-nginx.svc.cluster.local:80/"
WRK_POD="wrk2-client"

log()  { echo -e "\e[1;36m[5.6]\e[0m $*"; }
warn() { echo -e "\e[1;33m[5.6]\e[0m $*"; }

wrk_exec() { kubectl -n "${NS}" exec "${WRK_POD}" -- bash -c "$1" 2>&1; }

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

# ── CDF 데이터 추출 (Lua done 콜백, 6001 포인트) ─────────────────────
# wrk2 출력에서 Lua done 콜백이 생성한 ---CDF_START--- ~ ---CDF_END--- 구간 파싱
# 입력: wrk2 출력 파일, 대상 CDF CSV 파일, 메타데이터(label,rps,conns,trial)
CDF_POINTS="${CDF_POINTS:-6000}"

extract_cdf() {
    local file="$1" cdf_file="$2" label="$3" rps="$4" conns="$5" trial="$6"

    if [[ ! -f "${file}" ]] || [[ ! -s "${file}" ]]; then
        return
    fi

    awk -v label="${label}" -v rps="${rps}" -v conns="${conns}" -v trial="${trial}" '
    /---CDF_START---/ { in_cdf = 1; next }
    /---CDF_END---/ { exit }
    in_cdf && NF >= 1 {
        split($0, a, ",")
        if (a[1]+0 >= 0) {
            printf "%s,%s,%s,%s,%s,%s\n", label, rps, conns, trial, a[2], a[1]
        }
    }
    ' "${file}" >> "${cdf_file}"
}

# ── wrk2 출력 파싱 (단위 → μs 정규화) ───────────────────────────────
# 입력: wrk2 --latency 출력 파일
# 출력: p50_us,p75_us,p90_us,p99_us,p999_us,mean_us,actual_rps,total_reqs,transfer_kbps,errors,saturated
parse_wrk2_result() {
    local file="$1" target_rps="${2:-0}"

    if [[ ! -f "${file}" ]] || [[ ! -s "${file}" ]]; then
        echo "0,0,0,0,0,0,0,0,0,0,1"
        return
    fi

    awk -v target="${target_rps}" '
    function to_us(val) {
        if (val ~ /ms$/) { gsub(/ms$/, "", val); return val * 1000 }
        if (val ~ /us$/) { gsub(/us$/, "", val); return val * 1 }
        if (val ~ /s$/)  { gsub(/s$/,  "", val); return val * 1000000 }
        return 0
    }
    function to_kbps(val) {
        if (val ~ /GB$/) { gsub(/GB$/, "", val); return val * 1048576 }
        if (val ~ /MB$/) { gsub(/MB$/, "", val); return val * 1024 }
        if (val ~ /KB$/) { gsub(/KB$/, "", val); return val * 1 }
        if (val ~ /B$/)  { gsub(/B$/,  "", val); return val / 1024 }
        return 0
    }
    /^ *50\.000%/  && !p50  { p50  = to_us($2) }
    /^ *75\.000%/  && !p75  { p75  = to_us($2) }
    /^ *90\.000%/  && !p90  { p90  = to_us($2) }
    /^ *99\.000%/  && !p99  { p99  = to_us($2) }
    /^ *99\.900%/  && !p999 { p999 = to_us($2) }
    /^#\[Mean/ {
        gsub(/[^0-9.]/, " ", $0)
        split($0, vals, " ")
        for (i in vals) {
            if (vals[i]+0 > 0 && !mean_ms) { mean_ms = vals[i]; break }
        }
    }
    /Requests\/sec:/  { rps = $2 }
    /Transfer\/sec:/  { tput = to_kbps($2) }
    /requests in/     { reqs = $1 }
    /Socket errors:/ {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^[0-9]+$/ && $i+0 > 0) errs += $i+0
        }
    }
    END {
        mean_us = mean_ms * 1000
        sat = (target > 0 && rps+0 < target * 0.95) ? 1 : 0
        printf "%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%d,%.2f,%d,%d\n",
            p50+0, p75+0, p90+0, p99+0, p999+0, mean_us+0, rps+0, reqs+0, tput+0, errs+0, sat
    }
    ' "${file}"
}

# ── cross-trial 통계 계산 ────────────────────────────────────────────
compute_cross_trial_stats() {
    local summary_csv="$1" stats_csv="$2"

    echo "label,rps_target,connections,duration,trials,avg_p50_us,std_p50_us,avg_p99_us,std_p99_us,avg_p999_us,std_p999_us,avg_mean_us,std_mean_us,avg_actual_rps,std_actual_rps,avg_transfer_kbps,std_transfer_kbps" > "${stats_csv}"

    for rps in ${RPS_LIST}; do
        for conns in ${CONN_LIST}; do
            grep "^${LABEL},${rps},${conns}," "${summary_csv}" 2>/dev/null | awk -F',' \
                -v label="${LABEL}" -v rps="${rps}" -v conns="${conns}" -v dur="${DURATION}" '
            {
                n++
                sp50  += $6;  sq50  += $6*$6
                sp99  += $9;  sq99  += $9*$9
                sp999 += $10; sq999 += $10*$10
                smean += $11; sqmean += $11*$11
                srps  += $12; sqrps += $12*$12
                stput += $14; sqtput += $14*$14
            }
            END {
                if (n == 0) exit
                ap50  = sp50/n;  ap99  = sp99/n;  ap999 = sp999/n
                amean = smean/n; arps  = srps/n;  atput = stput/n
                v50   = sq50/n  - ap50*ap50;    sd50   = sqrt(v50   > 0 ? v50   : 0)
                v99   = sq99/n  - ap99*ap99;    sd99   = sqrt(v99   > 0 ? v99   : 0)
                v999  = sq999/n - ap999*ap999;  sd999  = sqrt(v999  > 0 ? v999  : 0)
                vmean = sqmean/n - amean*amean; sdmean = sqrt(vmean > 0 ? vmean : 0)
                vrps  = sqrps/n - arps*arps;    sdrps  = sqrt(vrps  > 0 ? vrps  : 0)
                vtput = sqtput/n - atput*atput;  sdtput = sqrt(vtput > 0 ? vtput : 0)
                printf "%s,%s,%s,%s,%d,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f\n",
                    label, rps, conns, dur, n,
                    ap50, sd50, ap99, sd99, ap999, sd999,
                    amean, sdmean, arps, sdrps, atput, sdtput
            }' >> "${stats_csv}" || true
        done
    done
}

# ── wrk 출력 파싱 (처리량 모드, closed-loop) ─────────────────────────
# wrk2 open-loop (50.000%, #[Mean]) 및 closed-loop (50%, Thread Stats) 형식 모두 지원
# 출력: rps,p50_us,p75_us,p90_us,p99_us,lat_avg_us,lat_sd_us,total_reqs,transfer_kbps,errors
parse_wrk_throughput() {
    local file="$1"
    [[ ! -f "${file}" || ! -s "${file}" ]] && { echo "0,0,0,0,0,0,0,0,0,0"; return; }

    awk '
    function to_us(val) {
        if (val ~ /ms$/) { gsub(/ms$/, "", val); return val * 1000 }
        if (val ~ /us$/) { gsub(/us$/, "", val); return val * 1 }
        if (val ~ /s$/)  { gsub(/s$/,  "", val); return val * 1000000 }
        return 0
    }
    function to_kbps(val) {
        if (val ~ /GB$/) { gsub(/GB$/, "", val); return val * 1048576 }
        if (val ~ /MB$/) { gsub(/MB$/, "", val); return val * 1024 }
        if (val ~ /KB$/) { gsub(/KB$/, "", val); return val * 1 }
        if (val ~ /B$/)  { gsub(/B$/,  "", val); return val / 1024 }
        return 0
    }
    # 퍼센타일: wrk2 "50.000%" 및 wrk "50%" 모두 매칭
    /^ *50(\.0+)?%/  { p50  = to_us($2) }
    /^ *75(\.0+)?%/  { p75  = to_us($2) }
    /^ *90(\.0+)?%/  { p90  = to_us($2) }
    /^ *99(\.0+)?%/  { p99  = to_us($2) }
    # wrk2 open-loop: #[Mean = ..., StdDeviation = ...] (단위: ms)
    /^#\[Mean/ {
        gsub(/[^0-9.]/, " ", $0)
        split($0, vals, " ")
        found = 0
        for (i = 1; i <= length(vals); i++) {
            if (vals[i]+0 > 0) {
                found++
                if (found == 1) lat_avg = vals[i] * 1000
                if (found == 2) { lat_sd = vals[i] * 1000; break }
            }
        }
    }
    # wrk closed-loop: Thread Stats Latency 행 (단위 접미사 포함)
    /^ *Latency/ && !/Distribution/ {
        lat_avg = to_us($2)
        lat_sd  = to_us($3)
    }
    /Requests\/sec:/  { rps = $2 }
    /Transfer\/sec:/  { tput = to_kbps($2) }
    /requests in/     { reqs = $1 }
    /Socket errors:/ {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^[0-9]+$/ && $i+0 > 0) errs += $i+0
        }
    }
    END {
        printf "%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%d,%.2f,%d\n",
            rps+0, p50+0, p75+0, p90+0, p99+0, lat_avg+0, lat_sd+0, reqs+0, tput+0, errs+0
    }
    ' "${file}"
}

# ── 처리량 cross-trial 통계 ──────────────────────────────────────────
compute_throughput_cross_trial_stats() {
    local summary_csv="$1" stats_csv="$2"

    echo "label,connections,duration,trials,avg_rps,std_rps,avg_p50_us,std_p50_us,avg_p99_us,std_p99_us,avg_transfer_kbps,std_transfer_kbps" > "${stats_csv}"

    for conns in ${CONN_LIST}; do
        grep "^${LABEL},${conns},[0-9]*," "${summary_csv}" 2>/dev/null | awk -F',' \
            -v label="${LABEL}" -v conns="${conns}" -v dur="${DURATION}" '
        {
            n++
            srps += $5; sqrps += $5*$5
            sp50 += $6; sqp50 += $6*$6
            sp99 += $9; sqp99 += $9*$9
            stput += $13; sqtput += $13*$13
        }
        END {
            if (n == 0) exit
            arps = srps/n; ap50 = sp50/n; ap99 = sp99/n; atput = stput/n
            vrps = sqrps/n - arps*arps;   sdrps  = sqrt(vrps  > 0 ? vrps  : 0)
            vp50 = sqp50/n - ap50*ap50;   sdp50  = sqrt(vp50  > 0 ? vp50  : 0)
            vp99 = sqp99/n - ap99*ap99;   sdp99  = sqrt(vp99  > 0 ? vp99  : 0)
            vtput = sqtput/n - atput*atput; sdtput = sqrt(vtput > 0 ? vtput : 0)
            printf "%s,%s,%s,%d,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f\n",
                label, conns, dur, n, arps, sdrps, ap50, sdp50, ap99, sdp99, atput, sdtput
        }' >> "${stats_csv}" || true
    done
}

# ── deploy ───────────────────────────────────────────────────────────
do_deploy() {
    log "배포 시작"
    kubectl apply -f "${SCRIPT_DIR}/00-namespace.yaml"
    kubectl apply -f "${SCRIPT_DIR}/nginx-configmap.yaml"
    kubectl apply -f "${SCRIPT_DIR}/01-nginx-deployment.yaml"
    kubectl apply -f "${SCRIPT_DIR}/02-wrk2-pod.yaml"

    log "Nginx 준비 대기..."
    kubectl -n "${NS}" rollout status deployment/nginx-bench --timeout=120s
    log "wrk2 Pod 대기..."
    kubectl -n "${NS}" wait --for=condition=Ready pod/${WRK_POD} --timeout=120s

    log "Nginx Pod:"
    kubectl -n "${NS}" get pods -o wide

    # wrk2 바이너리 확인
    wrk_exec 'ls -la /tools/bin/wrk' || { warn "wrk2 바이너리 없음"; return 1; }
    log "deploy 완료"
}

# ── 공통 setup (deploy + 정책 + 연결확인 + 워밍업) ─────────────────
do_setup() {
    do_deploy
    mkdir -p "${RESULT_HOST}"
    apply_policy

    log "서버 연결 확인..."
    local connected=false
    for i in $(seq 1 30); do
        if wrk_exec "/tools/bin/wrk -t1 -c1 -d1s -R1 ${SERVER_URL}" &>/dev/null; then
            connected=true; break
        fi
        sleep 1
    done
    if [[ "${connected}" != "true" ]]; then
        warn "서버 연결 실패 (30초 타임아웃)"; return 1
    fi
    log "서버 연결 확인 완료"

    log "===== Warm-up (${WARMUP_SEC}초, RPS=5000, c=100) ====="
    wrk_exec "/tools/bin/wrk -t${THREADS} -c100 -d${WARMUP_SEC}s -R5000 ${SERVER_URL} > /dev/null 2>&1" || true
    log "Warm-up 완료"
    sleep 5
}

# ── latency (wrk2 -R 고정 RPS에서 지연시간 측정) ─────────────────────
do_latency() {
    do_setup

    # CDF Lua 스크립트 생성
    wrk_exec "cat > /tmp/cdf_report.lua << 'LUAEOF'
done = function(summary, latency, requests)
    io.write(\"---CDF_START---\\n\")
    local N = ${CDF_POINTS}
    for i = 0, N do
        local p = i / N * 99.999
        io.write(string.format(\"%.6f,%.3f\\n\", p / 100, latency:percentile(p)))
    end
    io.write(\"---CDF_END---\\n\")
end
LUAEOF"

    local summary="${RESULT_HOST}/${LABEL}_latency.csv"
    echo "label,rps_target,connections,trial,duration,p50_us,p75_us,p90_us,p99_us,p999_us,mean_us,actual_rps,total_reqs,transfer_kbps,errors,saturated" > "${summary}"

    local cdf_csv="${RESULT_HOST}/${LABEL}_cdf.csv"
    echo "label,rps_target,connections,trial,latency_us,percentile" > "${cdf_csv}"

    for trial in $(seq 1 "${TRIALS}"); do
        log "===== Latency Trial ${trial}/${TRIALS} ====="
        for rps in ${RPS_LIST}; do
            for conns in ${CONN_LIST}; do
                local tag="lat_rps${rps}_conn${conns}_trial${trial}"
                local remote="/results/${LABEL}_${tag}.txt"
                local local_f="${RESULT_HOST}/${LABEL}_${tag}.txt"

                log "  RPS=${rps} CONNS=${conns}"
                wrk_exec "/tools/bin/wrk -t${THREADS} -c${conns} -d${DURATION} -R${rps} --latency -s /tmp/cdf_report.lua ${SERVER_URL} > ${remote} 2>&1" || true

                kubectl cp "${NS}/${WRK_POD}:${remote}" "${local_f}" 2>/dev/null || \
                    wrk_exec "cat ${remote}" > "${local_f}" 2>/dev/null || true

                if [[ -f "${local_f}" && -s "${local_f}" ]]; then
                    local stats
                    stats=$(parse_wrk2_result "${local_f}" "${rps}")
                    echo "${LABEL},${rps},${conns},${trial},${DURATION},${stats}" >> "${summary}"
                    extract_cdf "${local_f}" "${cdf_csv}" "${LABEL}" "${rps}" "${conns}" "${trial}"

                    local p50_d p99_d mean_d rps_d sat_d
                    p50_d=$(echo "${stats}" | cut -d, -f1)
                    p99_d=$(echo "${stats}" | cut -d, -f4)
                    mean_d=$(echo "${stats}" | cut -d, -f6)
                    rps_d=$(echo "${stats}" | cut -d, -f7)
                    sat_d=$(echo "${stats}" | cut -d, -f11)
                    log "    p50=${p50_d}μs  p99=${p99_d}μs  mean=${mean_d}μs  rps=${rps_d}"
                    [[ "${sat_d}" == "1" ]] && warn "    *** SATURATED ***"
                else
                    warn "    결과 없음"
                fi
                sleep "${COOLDOWN}"
            done
        done
    done

    log "===== Latency Cross-trial 통계 ====="
    local stats_csv="${RESULT_HOST}/${LABEL}_latency_stats.csv"
    compute_cross_trial_stats "${summary}" "${stats_csv}"

    echo ""
    log "Per-trial:"
    column -t -s',' "${summary}" 2>/dev/null || cat "${summary}"
    echo ""
    log "Cross-trial (avg ± stddev):"
    column -t -s',' "${stats_csv}" 2>/dev/null || cat "${stats_csv}"

    local cdf_lines=$(( $(wc -l < "${cdf_csv}") - 1 ))
    log "CDF: ${cdf_csv} (${cdf_lines} 포인트)"
    echo ""
    log "완료 (mode=latency, label=${LABEL}, trials=${TRIALS}, rps=[${RPS_LIST}], conns=[${CONN_LIST}])"
}

# ── throughput (wrk closed-loop, 커넥션별 최대 RPS 측정) ──────────────
do_throughput() {
    do_setup

    local summary="${RESULT_HOST}/${LABEL}_throughput.csv"
    echo "label,connections,trial,duration,rps,p50_us,p75_us,p90_us,p99_us,lat_avg_us,lat_sd_us,total_reqs,transfer_kbps,errors" > "${summary}"

    for trial in $(seq 1 "${TRIALS}"); do
        log "===== Throughput Trial ${trial}/${TRIALS} ====="
        for conns in ${CONN_LIST}; do
            local tag="tput_conn${conns}_trial${trial}"
            local remote="/results/${LABEL}_${tag}.txt"
            local local_f="${RESULT_HOST}/${LABEL}_${tag}.txt"

            log "  CONNS=${conns} (max throughput, -R1000000)"
            wrk_exec "/tools/bin/wrk -t${THREADS} -c${conns} -d${DURATION} -R1000000 --latency ${SERVER_URL} > ${remote} 2>&1" || true

            kubectl cp "${NS}/${WRK_POD}:${remote}" "${local_f}" 2>/dev/null || \
                wrk_exec "cat ${remote}" > "${local_f}" 2>/dev/null || true

            if [[ -f "${local_f}" && -s "${local_f}" ]]; then
                local stats
                stats=$(parse_wrk_throughput "${local_f}")
                echo "${LABEL},${conns},${trial},${DURATION},${stats}" >> "${summary}"

                local rps_d p50_d p99_d sd_d
                rps_d=$(echo "${stats}" | cut -d, -f1)
                p50_d=$(echo "${stats}" | cut -d, -f2)
                p99_d=$(echo "${stats}" | cut -d, -f5)
                sd_d=$(echo "${stats}" | cut -d, -f7)
                log "    RPS=${rps_d}  p50=${p50_d}μs  p99=${p99_d}μs  lat_sd=${sd_d}μs"
            else
                warn "    결과 없음"
            fi
            sleep "${COOLDOWN}"
        done
    done

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
    log "완료 (mode=throughput, label=${LABEL}, trials=${TRIALS}, conns=[${CONN_LIST}])"
}

# ── cleanup ──────────────────────────────────────────────────────────
do_cleanup() {
    log "전체 정리"
    # 모든 정책 제거
    kubectl delete -f "${SCRIPT_DIR}/policies/kloudknox-policy.yaml" --ignore-not-found 2>/dev/null || true
    if helm status falco -n falco &>/dev/null; then
        helm upgrade falco falcosecurity/falco -n falco --reuse-values \
            --set-json 'customRules={}' --wait --timeout 120s 2>/dev/null || true
    fi
    kubectl delete -f "${SCRIPT_DIR}/policies/tetragon-policy.yaml" --ignore-not-found 2>/dev/null || true
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
        echo "  bash $0 latency    [vanilla|kloudknox|falco|tetragon]  # 지연시간 측정"
        echo "  bash $0 throughput [vanilla|kloudknox|falco|tetragon]  # 처리량(Max RPS) 측정"
        echo "  bash $0 deploy                                         # 인프라 배포"
        echo "  bash $0 cleanup                                        # 전체 정리"
        echo ""
        echo "환경변수:"
        echo "  TRIALS=3          반복 횟수 (기본 3)"
        echo "  WARMUP_SEC=10     워밍업 시간 (기본 10초)"
        echo "  DURATION=60s      측정 시간 (기본 60초)"
        echo "  THREADS=4         wrk 스레드 수 (기본 4)"
        echo "  COOLDOWN=10       측정 간 쿨다운 (기본 10초)"
        echo "  RPS_LIST='1000 5000 10000'       [latency] 목표 RPS 리스트"
        echo "  CONN_LIST='10 50 100 500 1000'   동시 연결 수 리스트"
        ;;
esac
