# Third-party notices and license scope

Original integration code, tests, and documentation contributed to this project
are offered under the Apache License 2.0 in LICENSE, with the attribution notices
in NOTICE. Releases through 1.0 were offered under the MIT license. This grant
covers only original project contributions and does not relicense third-party
code or material embedded in a patch or generated test fixture.

| Component | Source | Licensing / distribution status |
|---|---|---|
| DXMT integration patch | [DXMT fork](https://github.com/NerRobDog/dxmt) at `c5dc3a0dfe9108e667da43de871324bd298c9c02` | LGPL-2.1-or-later; original notices and license text retained under licenses/ |
| Wine Mac driver patch | [CodeWeavers Wine 26.3 source](https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz) | Existing Wine LGPL-2.1-or-later terms retained; this is not the proprietary CrossOver application |
| Runtime assembly reference | [Soju](https://github.com/BCD1210/soju/tree/3a350b32bf906dd2a509b18c642a5a2676de022a) | Separate upstream project; GPL-3.0 scripts are referenced, not relicensed or vendored as project code |
| DXMT build dependencies | LLVM, DirectX headers, Metal toolchain, build tools | Separate upstream licenses; not included in this repository |
| Native runtime dependencies | Soju's referenced library stack, FreeType, SDL2, Wine Mono, and their dependencies | License texts for the bundled libraries ship in the app under `Contents/Resources/Licenses` |
| Apple support components and Rosetta | Apple | Proprietary; absent from this repository, bundled in the app under Apple's accompanying license, not covered by the project's Apache 2.0 license or the Wine/DXMT licenses |
| Battle.net and Overwatch | Blizzard | Proprietary; obtained through official channels and absent from this repository |

Upstream patches preserve their applicable terms. Generated tests incorporating
upstream source must retain those terms when distributed. No blanket Apache 2.0 claim
applies to the assembled runtime. Corresponding source, build recipes, notices,
and any required relinking information must accompany future binary distribution
as required by the individual component licenses.

This repository does not grant rights to any third-party trademarks or game
assets. Source availability is distinct from permission to redistribute Apple
components or to market the complete runtime for a particular intended use.
