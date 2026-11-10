#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_TMP=$(mktemp -d /tmp/vox321-tests.XXXXXX)
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$TEST_TMP"' EXIT
swiftc scripts/task321/Regressions.swift scripts/task321/TestDoubles.swift Vox/Services/{AliasService,ConfigService,LLMService,STTService,ProcessRunner,JSONBackupStore}.swift -framework Cocoa -o "$TEST_TMP/regressions"
"$TEST_TMP/regressions"
swiftc scripts/test-alias.swift Vox/Services/{AliasService,JSONBackupStore}.swift -o "$TEST_TMP/test-alias"
"$TEST_TMP/test-alias"
swiftc scripts/task321/BaselineCompatible.swift scripts/task321/TestDoubles.swift Vox/Services/{AliasService,ConfigService,LLMService,STTService,ProcessRunner,JSONBackupStore}.swift -framework Cocoa -o "$TEST_TMP/compatible"
"$TEST_TMP/compatible"
swiftc scripts/task321/R2Boundaries.swift scripts/task321/TestDoubles.swift Vox/Services/{ConfigService,STTService,ProcessRunner,JSONBackupStore}.swift -framework Cocoa -framework AVFoundation -o "$TEST_TMP/r2-boundaries"
"$TEST_TMP/r2-boundaries"
swiftc scripts/task321/BackupCleanupFailure.swift scripts/task321/TestDoubles.swift Vox/Services/{ConfigService,STTService,ProcessRunner,JSONBackupStore}.swift -framework Cocoa -framework AVFoundation -o "$TEST_TMP/backup-cleanup"
"$TEST_TMP/backup-cleanup"
