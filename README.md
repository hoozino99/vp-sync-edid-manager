# VP Stage Sync & EDID Manager

17대 렌더 노드의 EDID 및 프레임락 동기화를 중앙에서 관리하는 웹 대시보드.

## 구조

```
vp-sync-manager/
├── central/
│   ├── config.py          # 노드 IP, 인증 정보, 설정
│   ├── server.py          # FastAPI 대시보드 서버 (port 8500)
│   ├── node_remote.py     # PowerShell Invoke-Command 원격 실행
│   ├── requirements.txt
│   └── static/
│       └── index.html     # 다크 테마 웹 대시보드
├── remote_scripts/
│   ├── get_status.ps1     # 노드 상태 조회 (GPU, EDID, Sync)
│   ├── fix_edid_sync.ps1  # EDID/Sync 수정 스크립트
│   └── nvapi_helper.py    # NvAPI 헬퍼
├── build/
│   └── build_exe.py       # PyInstaller 빌드 스크립트
└── README.md
```

## 사전 준비

### 렌더 노드 (Windows)

1. **WinRM 활성화** (관리자 PowerShell):
   ```powershell
   Enable-PSRemoting -Force
   Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true
   Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true
   ```

2. **방화벽**: TCP 5985 포트 허용

### 중앙 관리 PC (Windows)

1. **TrustedHosts 설정**:
   ```powershell
   Set-Item WSMan:\localhost\Client\TrustedHosts -Value "10.10.10.*" -Force
   ```

## 실행 (개발)

```bash
cd central
pip install -r requirements.txt
python server.py
```

브라우저에서 `http://localhost:8500` 접속.

## 빌드 (EXE)

```bash
python build/build_exe.py
```

`dist/` 폴더에 단일 실행 파일 생성.

## API

| Method | Endpoint | 설명 |
|--------|----------|------|
| GET | `/api/nodes` | 전체 노드 상태 |
| POST | `/api/nodes/{id}/fix?output_id=0` | 노드 EDID+Sync 수정 |
| POST | `/api/nodes/{id}/edid/load?output_id=0` | EDID 로드 |
| POST | `/api/nodes/{id}/edid/unload?output_id=0` | EDID 언로드 |
| POST | `/api/nodes/{id}/sync/enable` | Sync 활성화 |
| POST | `/api/nodes/{id}/sync/disable` | Sync 비활성화 |
| POST | `/api/fix-all-broken` | 고장 노드 일괄 수정 |
| WS | `/ws` | 실시간 상태 스트림 |
