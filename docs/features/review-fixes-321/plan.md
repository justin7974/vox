# Bugfix plan
1. Preserve tracked dirty/untracked baseline in detached worktree. Read findings/callers.
2. Fix findings with focused helpers and injected IO; never instantiate real profile/key store in tests.
3. Run alias suite, mocked HTTP/process/storage failure regressions, config stress and full compile-only. Compare baseline regressions where possible.
4. Freeze diff/source/evidence for Eagle. No build.sh/install/commit/push.
