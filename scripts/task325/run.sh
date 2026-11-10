#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_TMP=$(mktemp -d /tmp/vox325-edit.XXXXXX)
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$TEST_TMP"' EXIT
swiftc scripts/task325/EditCapture.swift scripts/task321/TestDoubles.swift Vox/Services/{InsertedTextAnchor,PasteService,ProcessRunner}.swift -framework Cocoa -o "$TEST_TMP/capture"
"$TEST_TMP/capture"
swiftc scripts/task325/{EditCoordinator,CoordinatorDoubles}.swift Vox/Services/InsertedTextAnchor.swift Vox/Coordinators/DictationCoordinator.swift Vox/Core/{VoxPhase,VoxError}.swift Vox/Utilities/TextFormatter.swift -framework Cocoa -o "$TEST_TMP/coordinator"
"$TEST_TMP/coordinator"
swiftc scripts/task325/{BaselineBehavior,CoordinatorDoubles,AnchorDouble}.swift Vox/Coordinators/DictationCoordinator.swift Vox/Core/{VoxPhase,VoxError}.swift Vox/Utilities/TextFormatter.swift -framework Cocoa -o "$TEST_TMP/behavior"
"$TEST_TMP/behavior"
