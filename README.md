# MacBuddy

<img src="Support/MacBuddy-icon.png" alt="MacBuddy icon" width="160">

MacBuddy는 화면 위에 떠 있는 작은 픽셀 캐릭터로 macOS의 시스템 컨디션을 보여주는 가벼운 메뉴 막대 앱입니다.

메모리 압력, swap, CPU 부하, 시동 디스크 여유 공간과 메모리를 많이 사용하는 앱을 **기기 안에서만** 확인합니다. 캐릭터 머리 위의 작은 에너지바로 전체 상태를 빠르게 읽고, 캐릭터를 클릭하면 두 줄짜리 메모리 상태 메시지를 볼 수 있습니다.

## 주요 기능

- `Mint Buddy`, `Memory Chip`, `Strawberry Cake` 픽셀 캐릭터
- 대기·눈 깜빡임·호버·이동 방향 애니메이션
- 메모리 압력, swap, CPU, 디스크와 최근 30분 그래프
- 앱과 렌더러·헬퍼를 합산한 메모리 사용량 표시
- 사용자가 선택한 앱에만 일반 종료를 요청하는 안전한 메모리 최적화
- 로그인 시 자동 실행
- 네트워크 요청, 계정, 분석 도구, 광고 없음

## 요구 사항

- macOS 14 Sonoma 이상
- Apple Silicon 또는 Intel Mac

## 설치 — unsigned beta

1. [최신 GitHub Release](https://github.com/Jae-Park/MacBuddy/releases/latest)에서 DMG를 다운로드합니다.
2. DMG를 열고 `MacBuddy.app`을 Applications 폴더로 드래그합니다.
3. Developer ID로 서명되지 않은 베타이므로 최초 실행 시 Finder에서 앱을 Control-클릭하고 **열기**를 선택합니다.

현재 배포판은 Apple Developer Program 없이 만든 ad-hoc signed beta입니다. macOS의 보안 경고가 표시되는 것이 정상이며, 터미널에서 보안 설정을 해제할 필요는 없습니다.

## 사용법

- 캐릭터 클릭: 메모리 상태 메시지 열기·닫기
- 캐릭터 드래그: 화면에서 위치 이동
- 캐릭터 우클릭: 캐릭터 선택, 메모리 최적화, About
- 메뉴 막대 얼굴 아이콘: 상세 지표, 그래프, 메모리 사용 앱과 설정

`Optimize Memory…`는 캐시를 지우거나 RAM을 강제로 비우지 않습니다. 선택한 앱에는 저장할 기회를 주는 macOS 일반 종료 요청만 보내며, Finder·시스템 서비스·MacBuddy·현재 사용 중인 앱은 보호합니다.

## 소스에서 빌드

Xcode와 Swift 6 toolchain이 필요합니다.

```bash
git clone https://github.com/Jae-Park/MacBuddy.git
cd MacBuddy
./Scripts/build-app.sh
open dist/MacBuddy.app
```

Universal unsigned release 패키지를 만들려면 다음을 실행합니다.

```bash
./Scripts/package-release.sh
```

## 개인정보 및 안전 원칙

- 모든 시스템 정보는 로컬에서만 처리하며 외부로 보내지 않습니다.
- 메모리 최적화는 사용자가 직접 실행할 때만 동작합니다.
- 강제 종료, 캐시 삭제, 무조건적인 RAM purge를 하지 않습니다.
- 알림은 메뉴 막대에서 사용자가 직접 켰을 때만 요청합니다.
- 48×48 PNG 프레임을 nearest-neighbor로 표시해 픽셀 윤곽과 낮은 렌더링 비용을 유지합니다.

## Source availability

소스는 동작과 개인정보 처리를 투명하게 확인할 수 있도록 공개합니다. 재사용 라이선스는 아직 선택하지 않았습니다.

Created by **Jaeyong Park**.
