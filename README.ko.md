<h1 align="center">
  <img src="app/Resources/Banner.png" width="640" alt="Recall">
</h1>

<p align="center"><sub><a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · 한국어</sub></p>

<h3 align="center">Mac에서 오버워치를 플레이하세요.</h3>

<p align="center">Recall은 Apple 실리콘 Mac에서 오버워치를 플레이할 수 있게 해 주는 무료 오픈 소스 앱입니다.</p>

<p align="center">
  <a href="https://github.com/AsherJN/recall/releases/latest"><img src="https://img.shields.io/badge/Mac%EC%9A%A9_%EB%AC%B4%EB%A3%8C_%EB%8B%A4%EC%9A%B4%EB%A1%9C%EB%93%9C-FFAA2E?style=for-the-badge" height="40" alt="Mac용 Recall 무료 다운로드"></a>
  <a href="https://discord.gg/pexasKezCn"><img src="https://img.shields.io/badge/Discord_%EC%B0%B8%EC%97%AC%ED%95%98%EA%B8%B0-5865F2?style=for-the-badge&amp;logo=discord&amp;logoColor=white" height="40" alt="Recall Discord 참여하기"></a>
</p>

<p align="center"><sub>M1 이상 · macOS 26.5 이상 · Apple 공증 완료 · 넥슨 연동 한국 계정 지원</sub></p>

<p align="center"><sub>Josh 제작 · <a href="#recall을-만든-이유">프로젝트 응원하기</a></sub></p>

<table align="center">
  <tr>
    <td align="center" width="50%"><h2>+70%</h2>평균 FPS</td>
    <td align="center" width="50%"><h2>5×</h2>하위 1% FPS</td>
  </tr>
  <tr>
    <td align="center"><h2>95%</h2>끊김 감소</td>
    <td align="center"><h2>최대 66×</h2>마우스 업데이트 빈도</td>
  </tr>
</table>

<p align="center"><sub>같은 14인치 MacBook Pro(M1 Pro, 16GB)에서 같은 사용자 지정 경기로 CrossOver와 비교했습니다. 마우스: 8,000Hz 마우스를 쓰면 Recall은 초당 최대 8,000회, CrossOver는 120회 업데이트합니다.</sub></p>

https://github.com/user-attachments/assets/c0f5cac1-67fb-4b75-8bf9-06ccf402ae42

<p align="center"><sub><i>CrossOver 26.3과 Recall. 실시간 FPS는 Apple의 Metal 성능 HUD로 표시했습니다. 사용자 지정 게임 929PJ, 제작: <a href="https://www.reddit.com/r/linux_gaming/comments/1u4oanq/auto_precompile_shaders_for_overwatch_for_peak/">u/Working_Dealer_5102</a>.</i></sub></p>

Recall은 Apple 실리콘에서 가장 최적화되고 매끄러운 오버워치 경험을 제공합니다. 모든 설정을 대신 해 주므로, PC에서처럼 Battle.net에 로그인하고 오버워치를 설치한 뒤 플레이를 누르기만 하면 됩니다. 게임은 Mac에서 직접 실행되며, Windows 설치나 CrossOver 라이선스, 터미널 명령어가 필요 없습니다.

## Recall을 써야 하는 이유

- **더 매끄러운 경기.** 같은 Mac, 같은 경기에서 Recall의 평균 FPS는 CrossOver보다 70% 높았고, 하위 1% FPS는 거의 다섯 배, 끊김은 95% 적었습니다.
- **MetalFX 업스케일링으로 더 높은 FPS.** 오버워치가 더 적은 픽셀을 그리고 Apple의 MetalFX가 전체 해상도 화면으로 복원합니다. 1440p, 높음 프리셋에서 FPS가 최대 77% 올라갑니다. [작동 방식](docs/METALFX.md)(영어).
- **정확하게 따라오는 에임.** Recall은 macOS의 마우스 계층을 거치지 않고 마우스를 직접 읽으며, 모든 업데이트를 게임에 전달합니다. 8,000Hz 마우스라면 초당 최대 8,000번입니다. 플릭과 트래킹이 더 빨리 게임에 전달되고, 손이 움직인 그대로 정확히 들어갑니다.
- **무료.** 가격, 체험판, 구독, 광고, 계정이 없습니다. 코드는 오픈 소스입니다.
- **다운로드하고, 로그인하고, 플레이.** Recall이 필요한 것을 설치하고 Battle.net을 열어 줍니다. MacBook 화면이나 외장 모니터에서 플레이할 수 있으며, 울트라와이드와 5K도 지원합니다.
- **넥슨 연동 한국 계정.** 설정할 때 한국을 선택하면 넥슨과 연동된 한국 계정으로 플레이할 수 있습니다. Recall의 화면은 Mac의 언어를 따르며 한국어를 지원합니다.

## Recall과 CrossOver 비교

CrossOver는 Mac에서 Windows 게임을 즐기는 가장 인기 있는 방법이므로, 가장 의미 있는 비교 대상입니다. 저는 14인치 MacBook Pro(M1 Pro, 16GB)에서 같은 게임 설정으로 CrossOver 26.3과 Recall에서 같은 장면을 플레이하고, 각 앱이 화면에 표시한 모든 프레임을 기록했습니다.

<p align="center">
  <img src="app/Resources/ReadmeBenchmark.png" width="100%" alt="M1 Pro와 16GB 메모리를 탑재한 14인치 MacBook Pro에서의 사용자 지정 경기. 평균 FPS: CrossOver 58.4, Recall 99.6. 하위 1% FPS: CrossOver 7.4, Recall 36.0. 분당 끊김: CrossOver 39.5, Recall 2.0.">
</p>

| | CrossOver | Recall | 차이 |
|---|---:|---:|---:|
| **사용자 지정 경기** | | | |
| 평균 FPS | 58.4 | **99.6** | +70% |
| 하위 1% FPS | 7.4 | **36.0** | 4.9배 |
| 분당 끊김 | 39.5 | **2.0** | 95% 감소 |
| **훈련장** | | | |
| 평균 FPS | 84.0 | **120.7** | +44% |
| 하위 1% FPS | 26.2 | **55.2** | 2.1배 |
| 분당 끊김 | 4.2 | **0.5** | 88% 감소 |

<sub>하위 1% FPS는 가장 느린 1% 프레임 동안의 프레임률로, 한타에서 느껴지는 프레임 드롭입니다. 끊김은 50ms보다 오래 걸린 프레임을 말합니다. 두 앱 모두 macOS 26.6.2에서 오버워치를 1920 × 1080 전체 화면, 낮음 프리셋, 수직 동기화 끔, 동적 렌더 스케일 끔으로 실행했으며, CrossOver는 기본 그래픽 설정인 D3DMetal을 사용했습니다. 각 실행에서 로딩 화면과 메뉴를 제외한 약 2분의 게임 플레이를 측정했습니다. 전체 결과와 측정 방법은 [성능 노트](docs/PERFORMANCE.md)(영어)에 있습니다.</sub>

Recall이 어떻게 이런 결과를 내는지 궁금하다면 [Recall이 더 빠른 이유](docs/HOW-IT-WORKS.md)(영어)를 참고하세요.

**에임.** 오버워치는 플릭과 트래킹으로 승부가 갈리므로, 마우스 입력이 게임에 어떻게 전달되는지는 프레임률만큼 중요합니다. CrossOver는 macOS가 포인터를 업데이트하기를 초당 120번 기다리며, 게임이 숨겨진 커서를 화면 중앙으로 되돌릴 때마다 움직임이 조금씩 사라집니다. Recall은 macOS의 마우스 계층을 거치지 않고 마우스를 직접 읽으며, 모든 업데이트를 게임에 전달합니다. 8,000Hz 마우스라면 초당 최대 8,000번입니다. 커서를 중앙으로 되돌리지 않으므로 움직임을 잃지 않고 더 빨리 게임에 전달합니다. 처음에는 macOS에서 입력 모니터링을 허용하라는 안내가 나옵니다. Recall은 마우스만 읽습니다. [두 앱의 마우스 처리 방식](docs/PERFORMANCE.md#mouse-input)(영어).

**가격.** CrossOver는 1년 업데이트 포함 74달러, 평생 이용권은 494달러입니다. Recall은 무료입니다.

Windows 게임을 많이 한다면 CrossOver가 적합합니다. 오버워치를 주로 한다면 Recall이 바로 그 게임을 위해 만들어졌습니다.

<sub>가격은 2026년 10월 CodeWeavers 웹사이트 기준입니다.</sub>

## 시작하기

1. **[Recall 다운로드](https://github.com/AsherJN/recall/releases/latest)** 후 디스크 이미지를 열고 Recall을 응용 프로그램 폴더로 드래그하세요.
2. **Recall을 열고** 설정 단계를 따르세요. Battle.net(글로벌, 한국 또는 중국)과 Battle.net 언어를 선택하면 Recall이 모든 것을 준비하고 Battle.net을 엽니다.
3. **Battle.net에 로그인**하고 오버워치를 설치한 뒤 플레이를 누르세요.

| 필요한 것 | |
|---|---|
| Mac | Apple 실리콘: M1 이상. Intel Mac은 지원하지 않습니다. |
| macOS | macOS Tahoe 26.5 이상 |
| 메모리 | 16GB 권장 |
| 저장 공간 | Mac 또는 외장 SSD에 85~95GB의 여유 공간 |
| 기타 | 무료 블리자드 계정(한국은 넥슨 연동 계정), 인터넷 연결, Rosetta(Recall이 설정 중에 확인합니다) |

[설치 가이드](docs/INSTALLATION.md)(영어)에 외장 드라이브에 게임을 설치하는 방법 등 더 자세한 내용이 있습니다.

Homebrew를 선호하나요? [Homebrew로 설치하기](docs/INSTALLATION.md#installing-with-homebrew)(영어)를 참고하세요.

## 한국 계정 (넥슨)

Recall은 넥슨과 연동된 한국 계정을 지원합니다. 설정할 때 ‘Battle.net 선택’에서 한국을 선택하세요. 이미 설정했다면 설정 › 일반 › Battle.net 지역에서 바꿀 수 있습니다. 한국은 글로벌과 같은 Battle.net을 사용하므로, 전환해도 설치가 그대로 유지됩니다.

- **변경 사항.** 한국 오버워치는 시작할 때 보안 인증서를 확인하고, 넥슨의 안티치트가 가끔 게임 화면을 캡처합니다. Mac의 Wine은 이 두 가지를 그대로 처리하지 못해 게임이 종료되므로, Recall이 필요한 인증서를 추가하고 화면 캡처에는 빈 이미지를 전달합니다.
- **안티치트.** Recall은 넥슨의 안티치트를 끄지 않지만, 넥슨은 Mac에서의 플레이를 지원하지 않습니다.

## Recall을 만든 이유

<img src="app/Resources/AuthorPhotoRound.png" width="120" alt="Josh Nelson">

저는 Josh입니다. UCSB 기술경영 석사 과정을 졸업했고, 테크 제품을 만드는 걸 좋아합니다. PC 오버워치 커뮤니티에서 4년 넘게 활동해 왔고, 여행할 때도 MacBook으로 오버워치를 하고 싶다는 생각을 늘 해 왔습니다.

Mac 게이밍은 오랫동안 평판이 좋지 않았고, 수년 동안은 그럴 만했습니다. Apple 실리콘이 이를 바꿨습니다. 요즘 Mac은 놀라울 만큼 강력하고, Apple도 드디어 게임에 투자하고 있습니다. 이미 Mac을 쓰고 있는 사람들을 위해 더 많은 개발자가 게임을 만들어 주면 좋겠습니다. 그중에서도 가장 보고 싶은 게임이 오버워치입니다.

그때까지 Mac에서 더 쉽게 플레이할 수 있도록 Recall을 만들었습니다. 언젠가 블리자드가 오버워치를 Mac에 네이티브로 출시하기를, 그리고 이런 프로젝트가 그 수요가 있다는 걸 보여 주기를 바랍니다. 그때까지 즐겁게 플레이하세요 :)

Josh

제 작업을 응원하고 싶다면, 뉴스를 가장 투명하고 자유롭게, 개인정보를 지키며 볼 수 있도록 만든 제 무료 뉴스 앱 Mosaic News를 써 보세요.

커피 한 잔을 사 주시거나 이 저장소에 Star를 눌러 다른 Mac 플레이어들이 Recall을 찾을 수 있게 도와주셔도 큰 힘이 됩니다.

<p>
  <a href="https://mosaicnews.app/?utm_source=recall&amp;utm_medium=github&amp;utm_campaign=readme"><img src="app/Resources/ButtonMosaic.png" height="44" alt="Mosaic News 사용해 보기"></a>
  <a href="https://ko-fi.com/asherjn"><img src="app/Resources/ButtonCoffee.png" height="44" alt="Ko-fi에서 커피 한 잔 사 주기"></a>
  <a href="https://www.linkedin.com/in/asherjn/"><img src="app/Resources/ButtonLinkedIn.png" height="44" alt="LinkedIn의 Josh"></a>
</p>

## 자주 묻는 질문

<details>
<summary><b>정말 무료인가요?</b></summary>

네. 가격, 체험판, 구독, 광고, Recall 계정이 없으며 코드는 오픈 소스입니다. 오버워치는 무료로 플레이할 수 있으므로 블리자드 계정만 있으면 됩니다. Recall 덕분에 다른 소프트웨어 비용을 아꼈고 고마운 마음을 전하고 싶다면, [커피 한 잔을 사 주시거나](https://ko-fi.com/asherjn) [Mosaic News](https://mosaicnews.app/?utm_source=recall&utm_medium=github&utm_campaign=readme)를 써 보세요 :)
</details>

<details>
<summary><b>CrossOver, Windows, Boot Camp가 필요한가요?</b></summary>

아니요. Recall에는 Mac에서 오버워치를 실행하는 데 필요한 모든 것이 들어 있습니다. CrossOver를 구입하거나 Windows를 설치할 필요가 없으며, Apple 실리콘 Mac에는 Boot Camp가 없습니다.
</details>

<details>
<summary><b>계정은 안전한가요?</b></summary>

로그인은 Battle.net에서 직접 하며, Recall은 암호를 묻지 않습니다. Recall은 오버워치 게임 파일을 수정하거나, 게임에 코드를 주입하거나, 게임 메모리를 읽지 않습니다. Battle.net이 설치하는 것과 같은 Windows용 게임을 CrossOver의 기반 기술인 Wine으로 실행합니다. 블리자드와 넥슨은 Recall을 비롯한 어떤 방식으로든 Mac에서 오버워치를 플레이하는 것을 공식적으로 지원하지 않습니다. 한국 오버워치에는 넥슨의 안티치트가 포함되어 있으며, Recall은 이를 끄지 않습니다.
</details>

<details>
<summary><b>첫 경기에서 왜 끊기나요?</b></summary>

오버워치가 셰이더를 처음 사용할 때 Mac이 셰이더를 만드는데, 이때 끊김이 생깁니다. 경기가 끝날 때마다 Recall이 학습한 셰이더를 준비하므로 경기가 점점 부드러워집니다. 대부분의 플레이어는 5~10경기, 또는 셰이더 약 10,000~15,000개면 부드럽게 플레이합니다.

더 빨리 끝내려면 워크샵 코드 **929PJ** 게임을 5~10분 동안 실행하세요. **플레이 › 사용자 지정 게임 › 만들기 › 설정**으로 이동해 코드를 붙여넣어 불러온 다음 시작하면 됩니다. 또는 **플레이 › 사용자 지정 게임**에서 **500%** 검색 후 게임에 참가하세요.
</details>

<details>
<summary><b>외장 모니터를 사용할 수 있나요?</b></summary>

네. macOS 시스템 설정에서 외장 모니터를 주 디스플레이로 설정한 다음, 오버워치의 비디오 설정에서 해상도를 선택하세요. Recall이 기억합니다. [디스플레이 설정 안내](docs/SUPPORT.md#id-external-monitor)(영어)를 참고하세요.
</details>

<details>
<summary><b>게임을 외장 드라이브에 설치할 수 있나요?</b></summary>

네. 설정할 때 외장 SSD를 선택하고 플레이하는 동안 연결해 두세요. 지원되는 형식과 설정 방법은 [설치 가이드](docs/INSTALLATION.md)(영어)에 있습니다.
</details>

<details>
<summary><b>오버워치나 macOS가 업데이트되면 어떻게 되나요?</b></summary>

오버워치는 평소처럼 Battle.net을 통해 업데이트됩니다. 블리자드나 macOS 업데이트로 Mac 쪽 수정이 필요해지면 Recall 업데이트로 제공됩니다. Recall은 열릴 때 새 버전을 확인하며, 설치 시점은 직접 선택할 수 있습니다. Recall이 학습한 셰이더는 업데이트 후에도 유지되므로 처음부터 다시 시작하지 않아도 됩니다.
</details>

<details>
<summary><b>어떻게 제거하나요?</b></summary>

설정 › Recall 제거를 선택하세요. Recall과 Recall이 관리하는 게임 설치가 휴지통으로 이동합니다. 계정에는 영향이 없습니다. 자세한 내용은 [제거하기](docs/SUPPORT.md#uninstalling)(영어)를 참고하세요. Homebrew로 Recall을 설치했다면 대신 `brew uninstall --zap --cask recall`을 실행하세요.
</details>

## 도움말 및 기여

[Recall Discord](https://discord.gg/pexasKezCn)에서 도움을 받고, 설정을 비교하고, 다른 Mac 오버워치 플레이어를 만나 보세요.

[버그 보고](https://github.com/AsherJN/recall/issues/new?template=bug_report.yml) · [내 Mac에서의 실행 결과 공유](https://github.com/AsherJN/recall/issues/new?template=performance_report.yml) · [아이디어 제안](https://github.com/AsherJN/recall/issues/new?template=feature_request.yml)

문제 해결과 개인정보 보호 정보는 [지원 및 개인정보 보호](docs/SUPPORT.md)(영어)를 참고하세요. 보고서를 공유하기 전에 계정 이름과 개인 파일 경로를 지워 주세요.

코드에 관심이 있나요? [아키텍처](docs/DEVELOPMENT.md)와 [빌드 방법](docs/BUILDING.md)(영어)부터 시작해 보세요.

Recall은 CodeWeavers가 공개한 CrossOver 소스의 Wine, Feifan He가 만들고 NerRobDog이 포크한 DXMT, 그리고 Soju의 런타임 빌드 레시피를 사용합니다. Recall의 자체 코드는 [Apache 2.0](LICENSE) 라이선스를 따르며, 의존성과 패치는 각자의 라이선스를 유지합니다. [타사 고지 사항](THIRD_PARTY_NOTICES.md)을 참고하세요.

Recall은 독립 커뮤니티 프로젝트이며, 블리자드 엔터테인먼트, 넥슨, Apple, CodeWeavers와 제휴하거나 그 보증을 받지 않았습니다. Overwatch(오버워치), Mac, CrossOver 및 기타 제품 이름은 각 소유자의 상표입니다.
