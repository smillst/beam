#!/bin/bash

# Runs the Checker Framework's Nullness Checker over Beam, using a locally built Checker Framework.
# The Checker Framework's continuous integration jobs run this script.
#
# Usage: ./typecheck.sh GROUP
# where GROUP is one of:
#   part1, part2  type-check one group of modules (one CI job each)
#   all           type-check every module
#   list          print each group's compileJava tasks, without running them
#
# The modules are every Java project that applies the Checker Framework Gradle plugin without
# skipping it.  They are discovered at run time, so modules that are added to Beam are type-checked
# without changes to this script.
#
# Environment:
#   CHECKERFRAMEWORK  a Checker Framework checkout in which `./gradlew assembleForJavac` has run.
#                     Defaults to ../checker-framework.
#
# Run Gradle on JDK 21: Beam's Gradle version cannot run on JDK 25.  Do not pass -Pjava21Home or
# -Pjava25Home, which make BeamModulePlugin skip the Checker Framework.

set -e
set -o pipefail

# Patterns matched against Gradle project paths, in which `*` matches any sequence of characters.
# part1 is the Dataflow runner and the chain of modules it depends on (:sdks:java:core,
# :sdks:java:io:google-cloud-platform), which must be type-checked one after another and so bounds
# the time of any group that contains them.  Any module that no pattern in PART1 matches is in
# part2.  With 4 Gradle workers, part1 takes about 36 minutes and part2 about 31 minutes.  More
# groups would not be faster, because every group type-checks :sdks:java:core and part1's chain
# cannot be split.
PART1=(
  ':sdks:java:core'
  ':sdks:java:io:google-cloud-platform'
  ':runners:google-cloud-dataflow-java*'
)

GROUP="$1"
case "$GROUP" in
  part1 | part2 | all | list) ;;
  *)
    echo "Usage: $0 {part1|part2|all|list}" >&2
    exit 2
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$SCRIPT_DIR"

if [ -z "${CHECKERFRAMEWORK}" ]; then
  CHECKERFRAMEWORK="$(cd .. && pwd -P)/checker-framework"
fi
for jar in checker.jar checker-qual.jar; do
  if [ ! -f "${CHECKERFRAMEWORK}/checker/dist/${jar}" ]; then
    echo "$0: ${CHECKERFRAMEWORK}/checker/dist/${jar} does not exist." >&2
    echo "Set CHECKERFRAMEWORK and run \`./gradlew assembleForJavac\` there." >&2
    exit 1
  fi
done
export CHECKERFRAMEWORK

# Every project must be configured to discover which ones run the Checker Framework.
GRADLE_ARGS=(-PcfVersion=local --console=plain --no-configure-on-demand)

# Runs "./gradlew" with the arguments after the first, retrying if the failure looks like a
# transient network problem.  The first argument is a space-separated list of the delays, in
# seconds, before successive retries; its last element must be 0, which means "do not retry again".
gradle_retry() {
  local log status delay
  local -a delays
  read -r -a delays <<< "$1"
  shift
  log="$(mktemp -t beam-gradle-retry.XXXXXX)"
  for delay in "${delays[@]}"; do
    set +e
    ./gradlew "$@" 2>&1 | tee "$log"
    status="${PIPESTATUS[0]}"
    set -e
    if [ "$status" -eq 0 ]; then
      rm -f "$log"
      return 0
    fi
    # The failure looks like a transient network problem if it is HTTP status code 429 or 403, which
    # Maven Central returns when it is throttling a client.  The pattern does not match Gradle's
    # "Could not resolve", so a missing dependency or a Checker Framework crash is not retried.
    if [ "$delay" -eq 0 ] \
      || ! grep -q -E '(status|response) code:? (403|429|5[0-9][0-9])|HTTP Status:? (403|429|5[0-9][0-9])|Connect(ion)? timed out|Connection (reset|refused)|Read timed out|Network is unreachable|UnknownHostException|Temporary failure in name resolution|Premature end of Content-Length|Remote host terminated the handshake' "$log"; then
      rm -f "$log"
      return "$status"
    fi
    echo "$0: \"./gradlew $*\" failed for an apparent network reason; retrying in ${delay} seconds." >&2
    sleep "$delay"
  done
}

# The init script selects the projects in $GROUP and registers a typecheckCheckerFramework task.
INIT_SCRIPT="$SCRIPT_DIR/typecheck-init.gradle"

GRADLE_ARGS+=(-I "$INIT_SCRIPT" -PtypecheckGroup="$GROUP" -PtypecheckPart1="$(IFS=,; echo "${PART1[*]}")")
if [ "$GROUP" = list ]; then
  gradle_retry "60 300 0" "${GRADLE_ARGS[@]}" -q typecheckCheckerFramework
else
  # Dependencies are resolved as the compileJava tasks run.  A retry re-runs only the tasks that did
  # not succeed, so it retries once:  a longer sequence could exceed the CI job's time limit.
  gradle_retry "60 0" "${GRADLE_ARGS[@]}" --continue typecheckCheckerFramework
fi
