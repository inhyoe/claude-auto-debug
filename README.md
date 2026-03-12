# claude-auto-debug

Claude Code CLI를 사용한 24/7 자동 코드 품질 개선 파이프라인.

프로젝트의 코드 품질 이슈를 주기적으로 탐지하고, 자동 수정 후, 검증을 통과한 변경만 반영합니다.

## 특징

- **무인 실행** — systemd timer로 주기적 자동 실행
- **안전한 격리** — git worktree에서 작업, main 브랜치 보호
- **중복 방지** — SHA 기반 dedup (변경 없으면 스킵)
- **검증 게이트** — 사용자 정의 검증 명령어 통과 시에만 머지
- **실패 안전** — 검증 실패 시 자동 폐기 + dead-letter 로그 보존
- **변경 제한** — 1회 실행당 수정 파일 수 제한 (기본 3개)

## 설치

```bash
git clone https://github.com/<your-username>/claude-auto-debug.git
cd claude-auto-debug
bash install.sh
```

install.sh가 수행하는 작업:
1. `~/.local/bin/claude-auto-debug/`에 스크립트 복사
2. `~/.config/claude-auto-debug/config.env` 생성 (최초 1회)
3. systemd user timer 등록 및 활성화

## 설정

```bash
nano ~/.config/claude-auto-debug/config.env
```

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `PROJECT_DIR` | (필수) | 대상 프로젝트 절대 경로 |
| `VALIDATION_CMD` | `bash scripts/run-tests.sh` | 변경 후 실행할 검증 명령어 |
| `ALLOWED_TOOLS` | `Read,Edit,Write,Glob,Grep,Bash` | Claude에 허용할 도구 |
| `MAX_FILES` | `3` | 1회 최대 수정 파일 수 |
| `LOG_RETENTION_DAYS` | `30` | 로그 보존 기간 (일) |
| `INTERVAL` | `6h` | 실행 주기 (systemd timer) |

**주기 변경 시**: config.env의 `INTERVAL`을 수정한 후 `bash install.sh`를 다시 실행하세요.

## 24/7 동작

사용자 세션 종료 후에도 timer가 동작하려면:

```bash
loginctl enable-linger $(whoami)
```

## 사용법

```bash
# 상태 확인
systemctl --user status auto-debug.timer

# 로그 확인
journalctl --user -u auto-debug.service -f

# 수동 실행
systemctl --user start auto-debug.service

# 일시 중지
systemctl --user stop auto-debug.timer

# 재개
systemctl --user start auto-debug.timer
```

## 제거

```bash
cd claude-auto-debug
bash uninstall.sh
```

설정(`~/.config/claude-auto-debug/`)과 로그는 보존됩니다.

## 동작 흐름

```
systemd timer (매 INTERVAL)
  │
  ▼
auto-debug.sh
  ├─ flock 단일 인스턴스 확인
  ├─ SHA 비교 (변경 없으면 스킵)
  ├─ git worktree 생성 (격리)
  ├─ claude -p 실행 (프롬프트 템플릿)
  ├─ MAX_FILES 초과 검사
  ├─ VALIDATION_CMD 실행
  ├─ 통과 → main 머지 + SHA 기록
  └─ 실패 → worktree 폐기 + dead-letter 로그
```

## 요구사항

- Linux (systemd 기반)
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) 설치 및 인증 완료
- git
- bash, flock, envsubst (`gettext` 패키지)

## 라이선스

MIT
