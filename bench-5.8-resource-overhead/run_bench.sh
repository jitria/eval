#!/usr/bin/env bash
###############################################################################
# run_bench.sh — 5.8 Pod Density (v4)
#
# x축 = Pod 수 (1, 10, 25, 50, 75, 100), y축 = agent CPU/mem, node CPU/mem.
# Pod 구성: 70% syscall + 30% nginx, 모두 compute-node-2에 배치.
# syscall Pod: lat_syscall open + lat_connect 반복 실행.
# nginx Pod: nginx:1.25-alpine + wrk2 부하.
#
# 사용법:
#   bash run_bench.sh run [vanilla|kloudknox|falco|tetragon]
#   bash run_bench.sh cleanup
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

NS_RESOURCE="bench-resource"
NS_DENSITY="bench-density"
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
WARMUP_SEC="${WARMUP_SEC:-15}"
WRK_WARMUP_SEC="${WRK_WARMUP_SEC:-10}"

# wrk2 per-pod 설정
WRK_RPS_PER_POD="${WRK_RPS_PER_POD:-200}"
WRK_CONNS_PER_POD="${WRK_CONNS_PER_POD:-5}"
WRK_THREADS="${WRK_THREADS:-4}"

# Pod density 단계
POD_COUNTS="${POD_COUNTS:-1 10 25 50 75 100}"

# ── 파생값 ────────────────────────────────────────────────────────────
NUM_SAMPLES=$(( MEASURE_DURATION / SAMPLE_INTERVAL ))
NGINX_SVC="nginx-density-svc"
NGINX_URL="http://${NGINX_SVC}.${NS_DENSITY}.svc.cluster.local:80/"
WRK_POD="wrk2-client"
TCP_SERVER_POD="tcp-server"

log()  { echo -e "\e[1;36m[5.8]\e[0m $*"; }
warn() { echo -e "\e[1;33m[5.8]\e[0m $*"; }

# ── exec 헬퍼 ─────────────────────────────────────────────────────────
mon_exec()    { local p="$1"; shift; kubectl -n "${NS_RESOURCE}" exec "${p}" -- bash -c "$*" 2>&1; }
wrk_exec()    { kubectl -n "${NS_DENSITY}" exec "${WRK_POD}" -- bash -c "$1" 2>&1; }

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

# ── Pod 수 계산 (70% syscall, 30% nginx) ──────────────────────────────
get_nginx_count() {
    local total="$1"
    if (( total == 1 )); then
        echo 0
    else
        # ceiling: (total * 30 + 99) / 100
        echo $(( (total * 30 + 99) / 100 ))
    fi
}

get_syscall_count() {
    local total="$1"
    local nginx_n
    nginx_n=$(get_nginx_count "${total}")
    echo $(( total - nginx_n ))
}

# ── 정책 검증 ────────────────────────────────────────────────────────
verify_policy() {
    [[ "${LABEL}" == "vanilla" ]] && return
    log "정책 적용 검증 (${LABEL})"
    local ok=false
    case "${LABEL}" in
        kloudknox)
            for _i in $(seq 1 15); do
                if kubectl -n "${NS_DENSITY}" get kloudknoxpolicy.security.boanlab.com -o name 2>/dev/null | grep -q .; then
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

# ── 정책 적용/제거 ───────────────────────────────────────────────────
apply_policies() {
    [[ "${LABEL}" == "vanilla" ]] && return
    log "정책 적용 (${LABEL})"
    case "${LABEL}" in
        kloudknox) kubectl apply -f "${SCRIPT_DIR}/policies/kloudknox-policy.yaml" ;;
        falco)
            helm upgrade falco falcosecurity/falco -n falco --reuse-values \
                --set-file "customRules.bench-rules\.yaml=${SCRIPT_DIR}/policies/falco-rules.yaml" \
                --wait --timeout 120s ;;
        tetragon) kubectl apply -f "${SCRIPT_DIR}/policies/tetragon-policy.yaml" ;;
    esac
    verify_policy
    log "정책 적용 완료"
}

remove_policies() {
    [[ "${LABEL}" == "vanilla" ]] && return
    log "정책 제거 (${LABEL})"
    case "${LABEL}" in
        kloudknox)
            kubectl delete -f "${SCRIPT_DIR}/policies/kloudknox-policy.yaml" --ignore-not-found 2>/dev/null || true ;;
        falco)
            if helm status falco -n falco &>/dev/null; then
                helm upgrade falco falcosecurity/falco -n falco --reuse-values \
                    --set-json 'customRules={}' --wait --timeout 120s 2>/dev/null || true
            fi ;;
        tetragon)
            kubectl delete -f "${SCRIPT_DIR}/policies/tetragon-policy.yaml" --ignore-not-found 2>/dev/null || true ;;
    esac
    log "정책 제거 완료"
}

# ── 인프라 배포 ───────────────────────────────────────────────────────
deploy_infra() {
    log "===== 인프라 배포 ====="

    # 1. 네임스페이스
    log "네임스페이스 생성"
    kubectl apply -f "${SCRIPT_DIR}/00-namespace.yaml"

    # 2. 모니터 DaemonSet
    log "모니터 DaemonSet 배포"
    kubectl apply -f "${SCRIPT_DIR}/01-monitor-daemonset.yaml"
    kubectl -n "${NS_RESOURCE}" rollout status daemonset/resource-monitor --timeout=120s
    kubectl -n "${NS_RESOURCE}" get pods -o wide

    # 3. nginx ConfigMap (bench-density 네임스페이스)
    log "nginx ConfigMap 생성"
    kubectl -n "${NS_DENSITY}" create configmap nginx-bench-config \
        --from-literal=nginx.conf='
worker_processes auto;
worker_rlimit_nofile 65535;
events {
    worker_connections 16384;
    use epoll;
    multi_accept on;
}
http {
    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout  65;
    keepalive_requests 10000;
    access_log off;
    error_log  /var/log/nginx/error.log warn;
    server {
        listen 80 reuseport;
        server_name _;
        location / {
            return 200 '"'"'OK\n'"'"';
            add_header Content-Type text/plain;
        }
        location /health {
            return 200 '"'"'healthy\n'"'"';
            add_header Content-Type text/plain;
        }
    }
}
' --dry-run=client -o yaml | kubectl apply -f -

    # 4. tcp-server Pod (compute-node-2, bw_tcp -s)
    log "tcp-server Pod 배포"
    kubectl apply -f - <<'TCPEOF'
apiVersion: v1
kind: Pod
metadata:
  name: tcp-server
  namespace: bench-density
  labels:
    app: tcp-server
spec:
  nodeSelector:
    kubernetes.io/hostname: compute-node-2
  containers:
    - name: server
      image: ubuntu:22.04
      command: ["sleep", "infinity"]
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
        limits:
          cpu: 200m
          memory: 64Mi
      volumeMounts:
        - name: tools
          mountPath: /tools
  volumes:
    - name: tools
      hostPath:
        path: /opt/bench-tools
        type: Directory
TCPEOF
    kubectl -n "${NS_DENSITY}" wait --for=condition=Ready pod/tcp-server --timeout=120s

    # tcp-server에서 bw_tcp -s 시작
    local server_ip
    server_ip=$(kubectl -n "${NS_DENSITY}" get pod tcp-server -o jsonpath='{.status.podIP}')
    log "TCP 서버 시작 (bw_tcp -s on ${server_ip})"
    kubectl -n "${NS_DENSITY}" exec tcp-server -- bash -c 'nohup /tools/bin/bw_tcp -s >/dev/null 2>&1 &'
    sleep 2

    # 5. wrk2-client Pod (compute-node-1)
    log "wrk2-client Pod 배포"
    kubectl apply -f - <<'WRKEOF'
apiVersion: v1
kind: Pod
metadata:
  name: wrk2-client
  namespace: bench-density
  labels:
    app: wrk2-client
spec:
  nodeSelector:
    kubernetes.io/hostname: compute-node-1
  containers:
    - name: wrk2
      image: ubuntu:22.04
      command: ["sleep", "infinity"]
      resources:
        requests:
          cpu: 500m
          memory: 256Mi
        limits:
          cpu: "2"
          memory: 512Mi
      volumeMounts:
        - name: tools
          mountPath: /tools
  volumes:
    - name: tools
      hostPath:
        path: /opt/bench-tools
        type: Directory
WRKEOF
    kubectl -n "${NS_DENSITY}" wait --for=condition=Ready pod/wrk2-client --timeout=120s
    wrk_exec 'ls -la /tools/bin/wrk' || { warn "wrk2 바이너리 없음"; return 1; }

    # 6. nginx Deployment + Service (replicas=0)
    log "nginx Deployment + Service 생성 (replicas=0)"
    kubectl apply -f - <<NGINXEOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-density
  namespace: ${NS_DENSITY}
  labels:
    app: nginx-density
spec:
  replicas: 0
  selector:
    matchLabels:
      app: nginx-density
  template:
    metadata:
      labels:
        app: nginx-density
    spec:
      nodeSelector:
        kubernetes.io/hostname: compute-node-2
      containers:
        - name: nginx
          image: nginx:1.25-alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 64Mi
          volumeMounts:
            - name: config
              mountPath: /etc/nginx/nginx.conf
              subPath: nginx.conf
      volumes:
        - name: config
          configMap:
            name: nginx-bench-config
---
apiVersion: v1
kind: Service
metadata:
  name: ${NGINX_SVC}
  namespace: ${NS_DENSITY}
spec:
  selector:
    app: nginx-density
  ports:
    - port: 80
      targetPort: 80
  type: ClusterIP
NGINXEOF

    # 7. syscall Deployment (replicas=0, TCP_SERVER_IP 주입)
    log "syscall Deployment 생성 (replicas=0)"
    kubectl apply -f - <<SYSCEOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: syscall-density
  namespace: ${NS_DENSITY}
  labels:
    app: syscall-density
spec:
  replicas: 0
  selector:
    matchLabels:
      app: syscall-density
  template:
    metadata:
      labels:
        app: syscall-density
    spec:
      nodeSelector:
        kubernetes.io/hostname: compute-node-2
      containers:
        - name: syscall
          image: ubuntu:22.04
          command:
            - bash
            - -c
            - |
              while true; do
                /tools/bin/lat_syscall open 2>/dev/null || true
                /tools/bin/lat_connect \${TCP_SERVER_IP} 2>/dev/null || true
              done
          env:
            - name: TCP_SERVER_IP
              value: "${server_ip}"
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 64Mi
          volumeMounts:
            - name: tools
              mountPath: /tools
      volumes:
        - name: tools
          hostPath:
            path: /opt/bench-tools
            type: Directory
SYSCEOF

    log "인프라 배포 완료"
    log "  tcp-server IP: ${server_ip}"
}

# ── Scale Deployments ─────────────────────────────────────────────────
scale_to() {
    local pod_count="$1"
    local syscall_n nginx_n
    syscall_n=$(get_syscall_count "${pod_count}")
    nginx_n=$(get_nginx_count "${pod_count}")

    log "스케일링: pod_count=${pod_count} (syscall=${syscall_n}, nginx=${nginx_n})"
    kubectl -n "${NS_DENSITY}" scale deployment/syscall-density --replicas="${syscall_n}"
    kubectl -n "${NS_DENSITY}" scale deployment/nginx-density --replicas="${nginx_n}"

    # rollout 대기
    log "  syscall Deployment rollout 대기..."
    kubectl -n "${NS_DENSITY}" rollout status deployment/syscall-density --timeout=300s
    if (( nginx_n > 0 )); then
        log "  nginx Deployment rollout 대기..."
        kubectl -n "${NS_DENSITY}" rollout status deployment/nginx-density --timeout=300s
    fi

    # Ready Pod 수 확인
    local ready_syscall ready_nginx
    ready_syscall=$(kubectl -n "${NS_DENSITY}" get pods -l app=syscall-density --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    ready_nginx=$(kubectl -n "${NS_DENSITY}" get pods -l app=nginx-density --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    log "  Ready: syscall=${ready_syscall}, nginx=${ready_nginx}"
}

# ── per-trial 통계 (샘플 CSV → avg/stddev) ────────────────────────────
compute_sample_stats() {
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

# ── cross-trial 통계 (pod_count별) ───────────────────────────────────
compute_density_stats() {
    local summary_csv="$1" stats_csv="$2"

    echo "label,pod_count,trials,avg_agent_cpu,std_agent_cpu,avg_agent_mem,std_agent_mem,avg_node_cpu,std_node_cpu,avg_node_mem,std_node_mem" > "${stats_csv}"

    # summary: label,pod_count,trial,avg_ac,std_ac,avg_am,std_am,avg_nc,std_nc,avg_nm,std_nm,samples
    # pod_count별로 그룹핑, cross-trial avg/std of per-trial avg ($4,$6,$8,$10)
    local pc
    for pc in ${POD_COUNTS}; do
        awk -F',' -v lab="${LABEL}" -v pc="${pc}" '
        NR > 1 && $2 == pc {
            n++
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
            printf "%s,%s,%d,%.2f,%.2f,%.1f,%.1f,%.1f,%.1f,%.0f,%.0f\n",
                lab,pc,n,aac,dac,aam,dam,anc,dnc,anm,dnm
        }' "${summary_csv}" >> "${stats_csv}"
    done
}

# ═══════════════════════════════════════════════════════════════════════
# RUN
# ═══════════════════════════════════════════════════════════════════════
do_run() {
    log "===== Pod Density Benchmark (label=${LABEL}) ====="
    mkdir -p "${RESULT_HOST}"

    # 1. 인프라 배포
    deploy_infra

    # 2. 정책 적용 (1회)
    apply_policies

    # 3. 모니터 Pod 찾기 (compute-node-2: 워크로드 노드)
    local mon_pod
    mon_pod=$(get_monitor_pod "compute-node-2")
    [[ -n "${mon_pod}" ]] || { warn "monitor pod not found on compute-node-2"; return 1; }
    log "Monitor Pod: ${mon_pod} (compute-node-2)"

    local summary="${RESULT_HOST}/${LABEL}_density_summary.csv"
    echo "label,pod_count,trial,avg_agent_cpu,std_agent_cpu,avg_agent_mem,std_agent_mem,avg_node_cpu,std_node_cpu,avg_node_mem,std_node_mem,samples" > "${summary}"

    # 4. Density 루프
    for pod_count in ${POD_COUNTS}; do
        log "===== pod_count=${pod_count} ====="
        local nginx_n
        nginx_n=$(get_nginx_count "${pod_count}")

        # 스케일링
        scale_to "${pod_count}"

        # 워밍업
        log "워밍업 (sleep ${WARMUP_SEC}s)"
        sleep "${WARMUP_SEC}"

        if (( nginx_n > 0 )); then
            local wrk_rps=$(( WRK_RPS_PER_POD * nginx_n ))
            local wrk_conns=$(( WRK_CONNS_PER_POD * nginx_n ))
            log "wrk2 워밍업 (${WRK_WARMUP_SEC}s, RPS=${wrk_rps}, c=${wrk_conns})"

            # 서버 연결 확인
            local connected=false
            for _i in $(seq 1 30); do
                if wrk_exec "/tools/bin/wrk -t1 -c1 -d1s -R1 ${NGINX_URL}" &>/dev/null; then
                    connected=true; break
                fi
                sleep 1
            done
            [[ "${connected}" == "true" ]] || { warn "nginx 서버 연결 실패"; return 1; }

            wrk_exec "/tools/bin/wrk -t${WRK_THREADS} -c${wrk_conns} -d${WRK_WARMUP_SEC}s -R${wrk_rps} ${NGINX_URL} > /dev/null 2>&1" || true
        fi

        # Trial 루프
        for trial in $(seq 1 "${TRIALS}"); do
            log "  === Trial ${trial}/${TRIALS} (pod_count=${pod_count}) ==="
            flush_caches "${mon_pod}"

            local csv_name="${LABEL}_density_p${pod_count}_t${trial}.csv"

            # wrk2 부하 백그라운드 시작 (nginx > 0인 경우)
            if (( nginx_n > 0 )); then
                local wrk_rps=$(( WRK_RPS_PER_POD * nginx_n ))
                local wrk_conns=$(( WRK_CONNS_PER_POD * nginx_n ))
                local wrk_duration=$(( MEASURE_DURATION + 20 ))
                log "    wrk2 부하 시작 (RPS=${wrk_rps}, c=${wrk_conns}, ${wrk_duration}s)"
                wrk_exec "nohup /tools/bin/wrk -t${WRK_THREADS} -c${wrk_conns} -d${wrk_duration}s -R${wrk_rps} ${NGINX_URL} > /dev/null 2>&1 &"
                sleep 2
            fi

            # 모니터 실행 (blocking)
            log "    모니터링 (${NUM_SAMPLES} samples x ${SAMPLE_INTERVAL}s = ${MEASURE_DURATION}s)"
            mon_exec "${mon_pod}" "bash /scripts/monitor_in_pod.sh '${AGENT_NAME}' ${SAMPLE_INTERVAL} ${NUM_SAMPLES} ${pod_count} ${csv_name}" || true

            # wrk2 정리
            if (( nginx_n > 0 )); then
                wrk_exec "pkill -f wrk 2>/dev/null" || true
            fi

            # 결과 수집
            local local_csv="${RESULT_HOST}/${csv_name}"
            kubectl cp "${NS_RESOURCE}/${mon_pod}:/results/${csv_name}" "${local_csv}" 2>/dev/null || \
                mon_exec "${mon_pod}" "cat /results/${csv_name}" > "${local_csv}" 2>/dev/null || true

            # per-trial 통계
            if [[ -f "${local_csv}" ]] && [[ $(wc -l < "${local_csv}") -gt 1 ]]; then
                local stats
                stats=$(compute_sample_stats "${local_csv}")
                echo "${LABEL},${pod_count},${trial},${stats}" >> "${summary}"

                local avg_ac std_ac avg_am std_am avg_nc std_nc avg_nm std_nm samples
                IFS=',' read -r avg_ac std_ac avg_am std_am avg_nc std_nc avg_nm std_nm samples <<< "${stats}"
                log "    agent_cpu=${avg_ac}+-${std_ac}%  agent_mem=${avg_am}+-${std_am}MB  node_cpu=${avg_nc}+-${std_nc}%  node_mem=${avg_nm}+-${std_nm}MB (n=${samples})"
            else
                warn "    결과 없음"
            fi

            sleep 5
        done
    done

    # 5. Cross-trial 통계 (pod_count별)
    log "===== Cross-trial 통계 ====="
    local stats_csv="${RESULT_HOST}/${LABEL}_density_stats.csv"
    compute_density_stats "${summary}" "${stats_csv}"

    echo ""
    log "Per-trial summary:"
    column -t -s',' "${summary}" 2>/dev/null || cat "${summary}"
    echo ""
    log "Cross-trial stats (pod_count별 avg +- stddev):"
    column -t -s',' "${stats_csv}" 2>/dev/null || cat "${stats_csv}"

    # 6. 정책 제거
    remove_policies

    echo ""
    log "완료 (label=${LABEL}, trials=${TRIALS}, pod_counts=${POD_COUNTS})"
}

# ═══════════════════════════════════════════════════════════════════════
# CLEANUP
# ═══════════════════════════════════════════════════════════════════════
do_cleanup() {
    log "전체 정리"
    # 모든 정책 제거
    kubectl delete kloudknoxpolicy.security.boanlab.com --all -n "${NS_DENSITY}" --ignore-not-found 2>/dev/null || true
    if helm status falco -n falco &>/dev/null; then
        helm upgrade falco falcosecurity/falco -n falco --reuse-values \
            --set-json 'customRules={}' --wait --timeout 120s 2>/dev/null || true
    fi
    kubectl delete tracingpolicy --all --ignore-not-found 2>/dev/null || true
    # 네임스페이스 삭제
    kubectl delete namespace "${NS_DENSITY}" --ignore-not-found --grace-period=5 2>/dev/null || true
    kubectl delete namespace "${NS_RESOURCE}" --ignore-not-found --grace-period=5 2>/dev/null || true
    log "정리 완료"
}

# ═══════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════
case "${MODE}" in
    run)     do_run ;;
    cleanup) do_cleanup ;;
    *)
        echo "사용법:"
        echo "  bash $0 run [vanilla|kloudknox|falco|tetragon]  # Pod Density 벤치마크 실행"
        echo "  bash $0 cleanup                                  # 전체 정리"
        echo ""
        echo "환경변수:"
        echo "  TRIALS=3               반복 횟수"
        echo "  MEASURE_DURATION=60    측정 시간 (초)"
        echo "  SAMPLE_INTERVAL=5      샘플링 간격 (초)"
        echo "  WARMUP_SEC=15          스케일링 후 워밍업 시간 (초)"
        echo "  WRK_WARMUP_SEC=10      wrk2 워밍업 시간 (초)"
        echo "  WRK_RPS_PER_POD=200    nginx Pod당 RPS"
        echo "  WRK_CONNS_PER_POD=5    nginx Pod당 동시 연결"
        echo "  WRK_THREADS=4          wrk2 스레드"
        echo "  POD_COUNTS='1 10 25 50 75 100'  Pod 수 단계"
        ;;
esac
