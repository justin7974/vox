#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TMP_VOCAB_TEST=$(mktemp -d /tmp/vox-vocab-regression.XXXXXX)
trap 'trash "$TMP_VOCAB_TEST"' EXIT
swiftc scripts/task327-vocab/Stubs.swift scripts/task327-vocab/Tests.swift \
  Vox/Services/DictionaryAutoUpdateService.swift Vox/Services/DictionaryService.swift \
  Vox/Services/JSONBackupStore.swift Vox/Services/ConfigService.swift Vox/Utilities/JSONResponseParser.swift -o "$TMP_VOCAB_TEST/test-vocab"
"$TMP_VOCAB_TEST/test-vocab"
