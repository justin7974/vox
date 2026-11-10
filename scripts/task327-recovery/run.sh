#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_TMP=$(mktemp -d /tmp/vox327-recovery.XXXXXX)
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$TEST_TMP"' EXIT
swiftc scripts/task327-recovery/Recovery.swift scripts/task325/DictationDoubles.swift Vox/Coordinators/DictationCoordinator.swift Vox/Core/{VoxPhase,VoxError,RetryRecordingRequest}.swift Vox/Utilities/TextFormatter.swift -framework Cocoa -o "$TEST_TMP/recovery"
"$TEST_TMP/recovery"
swiftc scripts/task327-recovery/{LLMFailures,LLMDoubles}.swift Vox/Services/LLMService.swift -framework Cocoa -o "$TEST_TMP/llm"
"$TEST_TMP/llm"
swiftc scripts/task327-recovery/AudioBackups.swift Vox/Services/AudioService.swift Vox/Core/RetryRecordingRequest.swift -framework AVFoundation -o "$TEST_TMP/audio"
"$TEST_TMP/audio"
swiftc -sanitize=thread scripts/task327-recovery/DictionaryThreading.swift Vox/Services/{DictionaryService,JSONBackupStore}.swift -o "$TEST_TMP/dictionary-threads"
"$TEST_TMP/dictionary-threads"
