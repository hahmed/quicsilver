#!/bin/bash
# Find which test file triggers the SIGABRT
cd /Users/haroonahmed/src/github.com/hahmed/quicsilver

for f in test/*_test.rb test/**/*_test.rb; do
  result=$(timeout 30 bundle exec ruby -Ilib:test "$f" 2>&1)
  crash=$(echo "$result" | grep -c "SIGABRT\|Abort trap\|Signal 6")
  tests=$(echo "$result" | grep "runs," | head -1)
  if [ "$crash" -gt 0 ]; then
    echo "💥 CRASH: $f"
    echo "   $tests"
  else
    echo "✅ $f: $tests"
  fi
done
