# Flow — iOS port workspace

This repository is the **iOS 12.5.8 port of Flow** (Android: `../Flow`, Kotlin + Jetpack Compose + Material 3).

## Read before writing any code
1. `docs/PORT_SPEC.md` — the binding technical contract (platform limits, file tree, design tokens, data contracts). Every rule in it is mandatory.
2. `../Flow/AGENTS.md` — the upstream project's engineering rules, including the Anti-Slop design manifesto. They apply here.
3. `../Flow/README.md` — the feature list you must reach parity with.

## Non-negotiables
- Deployment target **iOS 12.0**, device family iPhone + iPad, arm64 only, UIKit, programmatic UI, zero third-party dependencies.
- No SwiftUI, no async/await, no Combine, no SF Symbols, no iOS 13+ APIs. `docs/PORT_SPEC.md` §2 lists the forbidden set.
- No placeholders, no TODOs, no empty implementations. If a feature needs platform-specific machinery, implement the iOS equivalent and document the mapping in `docs/PARITY.md`.
- Never modify `../Flow`. Never touch anything outside this repository except to read the Android source.
- After each file, keep going. Do not stop to ask questions — the specification is the answer.

## Workflow per phase
1. Read the relevant Android source under `../Flow/app/src/main/java/io/github/aedev/flow/` for the area you are porting.
2. Write complete Swift files into the tree defined in `docs/PORT_SPEC.md` §3.
3. Run `python3 scripts/audit.py` and fix every finding.
4. Update `docs/PARITY.md`.
