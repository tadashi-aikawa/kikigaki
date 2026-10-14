#!/bin/bash
set -euo pipefail

if [[ $# != 2 || ! $2 =~ ^[1-9][0-9]*$ ]]; then
    echo "Usage: bash scripts/check-swift-test-summary.sh <log> <expected-tests>" >&2
    exit 1
fi

# 終了コード0だけでは完走を保証できない。既知問題付きの成功集計も認めるが、
# XCTestの「Executed 0 tests」はSwift Testingの集計として扱わない。
awk -v expected="$2" '
    match($0, /Test run with [0-9]+ tests? passed after /) {
        split(substr($0, RSTART, RLENGTH), fields, " ")
        actual = fields[4]
        summaries++
    }
    END {
        if (summaries != 1) {
            printf "Swift Testing: expected one successful summary, found %d\n", summaries > "/dev/stderr"
            exit 1
        }
        if (actual != expected) {
            printf "Swift Testing: expected %d tests, summary reported %d\n", expected, actual > "/dev/stderr"
            exit 1
        }
        printf "Swift Testing: verified completion of all %d expected tests\n", actual
    }
' "$1"
