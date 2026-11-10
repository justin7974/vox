# Vox review fixes (task321)
Fix findings 1–12 from original Eagle report (5P1+7P2). Preserve dirty baseline and alias pipeline gates. Exclude model upgrade (#322), clipboard restoration (#13), installation and real credentials.

Acceptance: reject truncated LLM output; fail entire ASR on missing chunks; UTF16 insertion anchor and verified AX target/selection; CJK Latin boundaries; corrupt/stale-safe atomic JSON preserving unknown fields; bounded nonempty regex; checked Keychain and explicit clearing; own qwen key fallback; synchronized config; fail-closed BlackBox translate; bounded cancellable Whisper; metadata-only logs. Isolated mocked tests/full compile, then Eagle independent review. Live AX/application checks remain manual.

## r2 follow-up contract
GA c0289b97: success-empty ASR is silence, nil is failure; redact all apiKey fields in backups and retain5; duration-scaled Whisper timeout; skip AX capture when edit window is disabled/translate and bound AX messaging; synchronize Alias.lastError; Keychain outside the config state lock. Serialize writes on a separate queue, readers access short-lock snapshots. GA99fd72dc/a54bc0a1: reject only explicit length/max_tokens/content_filter markers, accept missing/custom normal markers. All include focused regressions and Eagle incremental review.
