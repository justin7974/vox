#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_TMP=$(mktemp -d /tmp/vox325-flow.XXXXXX)
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$TEST_TMP"' EXIT
swiftc scripts/task325/{DictationFlow,DictationDoubles}.swift Vox/Coordinators/DictationCoordinator.swift Vox/Core/{VoxPhase,VoxError}.swift Vox/Utilities/TextFormatter.swift -framework Cocoa -o "$TEST_TMP/flow"
"$TEST_TMP/flow"
swiftc scripts/task325/LegacyConfig.swift scripts/task321/TestDoubles.swift Vox/Services/{ConfigService,STTService,ProcessRunner,JSONBackupStore}.swift -framework Cocoa -framework AVFoundation -o "$TEST_TMP/legacy"
"$TEST_TMP/legacy"
