# MacBuddy

<img src="Support/MacBuddy-icon.png" alt="MacBuddy icon" width="160">

MacBuddy is a lightweight macOS menu bar app with a tiny floating pixel companion that shows your Mac's system health at a glance.

It monitors memory pressure, swap usage, CPU load, free startup-disk space, and memory-heavy apps **entirely on your device**. The small energy bar above the character gives you a quick health signal, while clicking the character shows a compact two-line memory status message.

## Features

- Three pixel characters: `Mint Buddy`, `Memory Chip`, and `Strawberry Cake`
- Idle, blink, hover, and directional movement animations
- Kernel memory pressure, a headroom estimate, swap, CPU, disk, and a recent 15-minute trend graph
- Combined memory usage for apps and their renderer/helper processes
- Safe memory optimization that sends a normal Quit request only to apps you select
- Instant language switching between System Default, 한국어, and English
- Automatic launch at login and secure opt-in updates through Sparkle
- No accounts, analytics, or ads; update checks contact GitHub only with user permission

## Requirements

- macOS 14 Sonoma or later
- Apple Silicon Mac (M1 or later)

## Install — unsigned beta

1. Download the DMG from the [latest GitHub Release](https://github.com/Jae-Park/MacBuddy/releases/latest).
2. Open the DMG and drag `MacBuddy.app` into the Applications folder.
3. This beta is not signed with a Developer ID. On first launch, Control-click the app in Finder and choose **Open**.

The current release is an ad-hoc signed beta built without the Apple Developer Program. A macOS security warning is expected; you do not need to disable security settings in Terminal.

## Usage

- Click the character: show or hide the memory status message
- Drag the character: move it around the screen
- Right-click the character: choose a character or language, optimize memory, or open About
- Click the face icon in the menu bar: open detailed metrics, graphs, memory-heavy apps, and settings
- `Language` in the menu bar panel or character menu: choose System Default, 한국어, or English
- `Updates…` or `Check for Updates…`: manually check the signed GitHub release feed

`Optimize Memory…` never deletes caches or forcibly purges RAM. It sends a normal macOS Quit request that gives selected apps a chance to save. Finder, system services, MacBuddy, and the app you were using before opening the optimizer are protected.

## Build from source

Xcode and a Swift 6 toolchain are required.

```bash
git clone https://github.com/Jae-Park/MacBuddy.git
cd MacBuddy
./Scripts/build-app.sh
open dist/MacBuddy.app
```

To create an Apple Silicon unsigned release package:

```bash
./Scripts/package-release.sh
```

## Privacy and safety

- All system information is processed locally and is never transmitted.
- Update checks send no system-health data; anonymous system profiling is disabled.
- Memory optimization runs only when you explicitly start it.
- MacBuddy does not force-quit apps, delete caches, or blindly purge RAM.
- Notification permission is requested only if you enable alerts from the menu bar panel.
- 48×48 PNG animation frames use nearest-neighbor rendering for crisp pixel edges and low rendering overhead.

## License

The source is available under the [PolyForm Noncommercial License 1.0.0](LICENSE). Noncommercial use, modification, and redistribution are permitted with the required copyright notice. Commercial use requires a separate written license from the author.

Created by **Jaeyong Park**.

---

## 한국어

MacBuddy는 화면 위에 떠 있는 작은 픽셀 캐릭터로 macOS의 시스템 상태를 한눈에 보여주는 가벼운 메뉴 막대 앱입니다.

메모리 압력, swap 사용량, CPU 부하, 시동 디스크 여유 공간과 메모리를 많이 사용하는 앱을 **기기 안에서만** 확인합니다. 캐릭터 머리 위의 작은 에너지바로 전체 상태를 빠르게 읽고, 캐릭터를 클릭하면 간결한 두 줄짜리 메모리 상태 메시지를 볼 수 있습니다.

## 주요 기능

- `Mint Buddy`, `Memory Chip`, `Strawberry Cake` 픽셀 캐릭터
- 대기·눈 깜빡임·호버·이동 방향 애니메이션
- macOS 커널 메모리 압력, 여유 추정치, swap, CPU, 디스크와 최근 15분 추이 그래프
- 앱과 렌더러·헬퍼를 합산한 메모리 사용량 표시
- 사용자가 선택한 앱에만 일반 종료를 요청하는 안전한 메모리 최적화
- 시스템 기본값, 한국어, English 언어 선택과 즉시 전환
- 로그인 시 자동 실행 및 Sparkle을 통한 안전한 선택형 업데이트
- 계정, 분석 도구, 광고 없음. 사용자가 허용한 업데이트 확인만 GitHub에 연결

## 요구 사항

- macOS 14 Sonoma 이상
- Apple Silicon 기반 맥(M1 이상)

## 설치 — unsigned beta

1. [최신 GitHub Release](https://github.com/Jae-Park/MacBuddy/releases/latest)에서 DMG를 다운로드합니다.
2. DMG를 열고 `MacBuddy.app`을 Applications 폴더로 드래그합니다.
3. Developer ID로 서명되지 않은 베타이므로 최초 실행 시 Finder에서 앱을 Control-클릭하고 **열기**를 선택합니다.

현재 배포판은 Apple Developer Program 없이 만든 ad-hoc signed beta입니다. macOS의 보안 경고가 표시되는 것이 정상이며, 터미널에서 보안 설정을 해제할 필요는 없습니다.

## 사용법

- 캐릭터 클릭: 메모리 상태 메시지 열기·닫기
- 캐릭터 드래그: 화면에서 위치 이동
- 캐릭터 우클릭: 캐릭터 또는 언어 선택, 메모리 최적화, About
- 메뉴 막대 얼굴 아이콘: 상세 지표, 그래프, 메모리 사용 앱과 설정
- 메뉴 막대 패널 또는 캐릭터 메뉴의 `언어`: 시스템 기본값, 한국어, English 선택
- `업데이트 확인…`: 서명된 GitHub 릴리스 피드를 수동으로 확인

`메모리 최적화…`는 캐시를 지우거나 RAM을 강제로 비우지 않습니다. 선택한 앱에는 저장할 기회를 주는 macOS 일반 종료 요청만 보내며, Finder·시스템 서비스·MacBuddy·최적화 창을 열기 전에 사용하던 앱은 보호합니다.

## 소스에서 빌드

Xcode와 Swift 6 toolchain이 필요합니다.

```bash
git clone https://github.com/Jae-Park/MacBuddy.git
cd MacBuddy
./Scripts/build-app.sh
open dist/MacBuddy.app
```

Apple Silicon 전용 unsigned release 패키지를 만들려면 다음을 실행합니다.

```bash
./Scripts/package-release.sh
```

## 개인정보 및 안전 원칙

- 모든 시스템 정보는 로컬에서만 처리하며 외부로 보내지 않습니다.
- 업데이트 확인에는 시스템 상태 데이터가 포함되지 않으며 익명 시스템 프로파일링도 비활성화합니다.
- 메모리 최적화는 사용자가 직접 실행할 때만 동작합니다.
- 강제 종료, 캐시 삭제, 무조건적인 RAM purge를 하지 않습니다.
- 알림은 메뉴 막대에서 사용자가 직접 켰을 때만 권한을 요청합니다.
- 48×48 PNG 프레임을 nearest-neighbor로 표시해 픽셀 윤곽과 낮은 렌더링 비용을 유지합니다.

## 라이선스

소스는 [PolyForm Noncommercial License 1.0.0](LICENSE)에 따라 공개합니다. 저작권 고지를 유지하는 비상업적 사용·수정·재배포는 허용하며, 상업적 사용에는 저자의 별도 서면 허가가 필요합니다.

만든 사람: **Jaeyong Park**
