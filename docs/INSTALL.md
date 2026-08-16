# Install MacBuddy

MacBuddy is currently distributed as an unsigned Apple Silicon beta. Download it only from the official [MacBuddy GitHub Releases](https://github.com/Jae-Park/MacBuddy/releases/latest) page.

## Requirements

- Apple Silicon Mac (M1 or later)
- macOS 14 Sonoma or later

## Install

1. Download `MacBuddy-*-arm64-unsigned.dmg` from the latest release.
2. Open the DMG.
3. Drag `MacBuddy.app` into the Applications folder.
4. Eject the DMG.
5. In Finder, open Applications, Control-click `MacBuddy`, and choose **Open**.
6. Confirm **Open** in the macOS dialog.

The Control-click step creates an exception for this copy without disabling macOS security globally.

## If macOS still blocks the app

First try to open MacBuddy once so the security message is registered. Then open **System Settings → Privacy & Security**, scroll to Security, and choose **Open Anyway** for MacBuddy. Apple notes that this option is available for about an hour after the blocked launch attempt.

Do not disable Gatekeeper and do not run an `xattr` removal command. For more context, see Apple's [Open a Mac app from an unknown developer](https://support.apple.com/guide/mac-help/mh40616/mac) guidance.

## Verify the download (optional)

Each release includes `SHA256SUMS.txt`. After downloading the DMG and checksum file into Downloads, run:

```bash
cd ~/Downloads
shasum -a 256 MacBuddy-*-arm64-unsigned.dmg
```

Compare the result with the DMG entry in `SHA256SUMS.txt` on the same release page.

## Updates

MacBuddy 0.5.0 is the first version with the updater. Versions before 0.5.0 require one manual install. After that, MacBuddy can check the signed GitHub feed and install EdDSA-verified updates.

---

## 한국어

MacBuddy는 현재 Apple Silicon 전용 unsigned beta로 배포됩니다. 공식 [MacBuddy GitHub Releases](https://github.com/Jae-Park/MacBuddy/releases/latest) 페이지에서만 다운로드하세요.

### 요구 사항

- Apple Silicon 기반 맥(M1 이상)
- macOS 14 Sonoma 이상

### 설치

1. 최신 릴리스에서 `MacBuddy-*-arm64-unsigned.dmg`를 다운로드합니다.
2. DMG를 엽니다.
3. `MacBuddy.app`을 응용 프로그램 폴더로 드래그합니다.
4. DMG를 꺼냅니다.
5. Finder에서 응용 프로그램을 열고 `MacBuddy`를 Control-클릭한 뒤 **열기**를 선택합니다.
6. macOS 확인 창에서 다시 **열기**를 선택합니다.

Control-클릭 방식은 macOS 보안 기능 전체를 끄지 않고 이 앱 복사본만 예외로 등록합니다.

### macOS가 계속 실행을 차단할 때

먼저 MacBuddy를 한 번 실행해 보안 메시지가 기록되게 합니다. 이후 **시스템 설정 → 개인정보 보호 및 보안**을 열고 보안 영역에서 MacBuddy의 **그래도 열기**를 선택합니다. Apple 안내에 따르면 이 버튼은 차단된 실행을 시도한 뒤 약 한 시간 동안 표시됩니다.

Gatekeeper를 비활성화하거나 `xattr` 제거 명령을 실행하지 마세요. 자세한 내용은 Apple의 [보안 설정을 덮어써서 앱 열기](https://support.apple.com/ko-kr/guide/mac-help/mh40617/mac) 안내를 참고하세요.

### 다운로드 검증(선택 사항)

각 릴리스에는 `SHA256SUMS.txt`가 포함됩니다. DMG와 체크섬 파일을 다운로드 폴더에 받은 뒤 다음 명령을 실행합니다.

```bash
cd ~/Downloads
shasum -a 256 MacBuddy-*-arm64-unsigned.dmg
```

출력된 값이 같은 릴리스 페이지의 `SHA256SUMS.txt`에 적힌 DMG 값과 일치하는지 확인합니다.

### 업데이트

MacBuddy 0.5.0은 업데이터가 포함된 첫 버전입니다. 0.5.0 이전 버전에서는 한 번 직접 설치해야 하며, 그 이후에는 서명된 GitHub 피드를 확인하고 EdDSA로 검증된 업데이트를 설치할 수 있습니다.
