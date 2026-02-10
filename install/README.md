# install — 벤치마크 도구 설치

SSH 접속 없이 kubectl만으로 양쪽 노드에 벤치마크 도구를 설치한다.

## 설치 대상

| 도구 | 설치 방법 | 용도 |
|------|----------|------|
| lmbench | 소스 빌드 (DaemonSet Pod 내) | syscall 워크로드 (5.5) |
| wrk2 | 소스 빌드 (DaemonSet Pod 내) | HTTP 벤치마크 (5.6) |
| bpftrace | 각 실험 DaemonSet에서 apt 설치 | syscall 트레이싱 (5.5, 5.7) |

## 동작 방식

1. privileged DaemonSet이 양쪽 노드에 배포됨
2. Pod 내부에서 소스 빌드 (apt-get, git clone, make)
3. 결과 바이너리가 hostPath `/opt/bench-tools/bin/`에 저장됨
4. 실험 Pod들이 이 경로를 hostPath로 마운트하여 사용

## 설치 경로 (호스트)

- 바이너리: `/opt/bench-tools/bin/`
- 소스: `/opt/bench-tools/src/`
- 결과: `/tmp/2026SoCC/`

## 사용법

```bash
# 설치 시작
bash install_tools.sh install

# 설치 상태 확인
bash install_tools.sh status

# 설치 Pod 정리 (바이너리는 호스트에 유지)
bash install_tools.sh cleanup
```
