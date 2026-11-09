# Contributing

Thanks for helping improve Resource Monitor!

## Getting started

1. Fork and clone the repo.
2. Build and run: `./build.sh && open ~/Applications/"Resource Monitor.app"` (or `swift run -c release`).
3. Create a branch: `git checkout -b feature/my-change`.

Requires macOS 14+ and the Swift 5.9+ toolchain.

## Where things live

- `Sources/ResourceMonitor/Sampler.swift`: data collection (CPU, memory, disk, network, processes, tips, quit actions)
- `Sources/ResourceMonitor/App.swift`: SwiftUI dashboard, charts, menu bar item

## Guidelines

- Keep the app dependency-free and sampling overhead low.
- Match the existing code style, and add comments only where the code isn't obvious.
- Anything that quits apps or touches user data must ask for confirmation.
- Include a screenshot in your PR for any UI change.
- Open an issue first for large changes.

## Pull requests

- Keep PRs focused on one change.
- Make sure CI (the build) passes.
- Describe what changed and why.

Look for issues labelled `good first issue` if you're new.
