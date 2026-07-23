# Worktree and multi-agent workflow

This document records both the original collaboration layout and the recommended
reproducible Git workflow.

## Original isolation layout

ClearScan was initially built before the main folder had Git history. To prevent
two coding agents from overwriting one another, the project used a plain isolated
copy:

```text
ClearScan/
├── ios/ClearScan/          # Codex-owned main implementation
├── minjun/
│   ├── worktree/           # Fable5 isolated copy (not a real Git worktree)
│   ├── FABLE5_PROMPT.md
│   └── artifacts/          # local reports, logs, and patches
└── work/
    └── open-source-review/ # temporary upstream clones
```

The word `worktree` described the isolation role, but it was not linked to a
`.git` directory. The public repository does not include those duplicated files,
logs, upstream clones, or private paths. Their purpose and integration boundary
are preserved here.

## Recommended Git worktrees

After cloning the public repository:

```bash
git clone https://github.com/fakeminjun7321/ClearScan.git
cd ClearScan

# Detection specialist
git worktree add ../ClearScan-detection \
  -b agent/document-detection main

# Google/export specialist
git worktree add ../ClearScan-google \
  -b agent/google-export main
```

Result:

```text
workspace/
├── ClearScan/              # main integration checkout
├── ClearScan-detection/    # agent/document-detection
└── ClearScan-google/       # agent/google-export
```

Sibling worktrees are preferred over nested worktrees. Each worker owns a
bounded file set, its own branch, and a separate DerivedData directory.

## Integration rules

1. Main checkout owns product-wide files and conflict resolution.
2. A worker changes only its assigned scope and adds focused tests.
3. Each worker commits to its own branch and opens a PR.
4. The integrator reviews the diff and verification level before merging.
5. Physical-device and live-Google claims require separate evidence.
6. Temporary input documents, logs, result bundles, and upstream clones stay
   under ignored local directories.

Clean up after merge:

```bash
git worktree remove ../ClearScan-detection
git branch -d agent/document-detection
git worktree prune
```

This layout lets multiple agents work concurrently without sharing uncommitted
files or accidentally treating one worker's build result as another's evidence.
