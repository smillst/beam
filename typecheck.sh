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
# without changes to this script: any module that no pattern in PART1 matches is in part2.
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
# the time of any group that contains them.  With
# 4 Gradle workers, part1 takes about 36 minutes and part2 about 31 minutes.  More groups would
# not be faster, because every group type-checks :sdks:java:core and part1's chain cannot be split.
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
if [ ! -f "${CHECKERFRAMEWORK}/checker/dist/checker.jar" ]; then
  echo "$0: ${CHECKERFRAMEWORK}/checker/dist/checker.jar does not exist." >&2
  echo "Set CHECKERFRAMEWORK and run \`./gradlew assembleForJavac\` there." >&2
  exit 1
fi
export CHECKERFRAMEWORK

# Every project must be configured to discover which ones run the Checker Framework.
GRADLE_ARGS=(-PcfVersion=local --console=plain --no-configure-on-demand)

# Runs "./gradlew" with the arguments after the first, retrying if the failure looks like a
# transient network problem, such as HTTP status code 429 or 403, which Maven Central returns when
# it is throttling a client.  The pattern does not match Gradle's "Could not resolve", so a
# missing dependency or a Checker Framework crash is not retried.  The first argument is a
# space-separated list of the delays, in seconds, before successive retries; its last element
# must be 0, which means "do not retry again".
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
    if [ "$delay" -eq 0 ] \
      || ! grep -q -E '(status|response) code:? (403|429|5[0-9][0-9])|HTTP Status:? (403|429|5[0-9][0-9])|Connect(ion)? timed out|Connection (reset|refused)|Read timed out|Network is unreachable|UnknownHostException|Temporary failure in name resolution|Premature end of Content-Length|Remote host terminated the handshake' "$log"; then
      rm -f "$log"
      return "$status"
    fi
    echo "$0: \"./gradlew $*\" failed for an apparent network reason; retrying in ${delay} seconds." >&2
    sleep "$delay"
  done
}

# The init script selects the projects in $GROUP.  Whether a project runs the Checker Framework is
# known only after the project is configured, so the selection is done in the same Gradle
# invocation that type-checks, which avoids configuring Beam twice.  It registers a
# typecheckCheckerFramework task in the root project.  For GROUP=list, the task prints each selected
# project's group and compileJava task; otherwise, it depends on each selected project's
# compileJava task.
INIT_SCRIPT="$(mktemp -t beam-typecheck.XXXXXX)"
# shellcheck disable=SC2064 # $INIT_SCRIPT is intentionally expanded now.
trap "rm -f '$INIT_SCRIPT'" EXIT
cat > "$INIT_SCRIPT" << 'EOF'
import java.util.regex.Pattern

// Converts a pattern in which `*` matches any sequence of characters to a regex.
def globToRegex = { String glob ->
  Pattern.compile(glob.split(/\*/, -1).collect { Pattern.quote(it) }.join('.*'))
}

gradle.projectsEvaluated {
  // Gradle also applies this init script to buildSrc, a nested build.
  if (gradle.parent != null) {
    return
  }
  def group = gradle.startParameter.projectProperties['typecheckGroup']
  def part1 = gradle.startParameter.projectProperties['typecheckPart1'].split(',').collect(globToRegex)
  def groupOf = { String path -> part1.any { it.matcher(path).matches() } ? 'part1' : 'part2' }

  def selected = []
  def disabled = []
  gradle.rootProject.allprojects.each { p ->
    if (p.plugins.hasPlugin('org.checkerframework')
        && !p.extensions.getByName('checkerFramework').skipCheckerFramework.get()) {
      def compileJava = p.tasks.findByName('compileJava')
      if (compileJava == null) {
        return
      }
      // BeamModulePlugin disables every task of a project that requires a newer Java version than
      // is available.
      if (!compileJava.enabled) {
        disabled << p.path
      } else if (group == 'list' || group == 'all' || groupOf(p.path) == group) {
        selected << p.path
      }
    }
  }
  selected.sort()

  if (!disabled.isEmpty()) {
    System.err.println('typecheck.sh: warning: not type-checking these projects, which require a newer Java version:')
    disabled.sort().each { System.err.println("  ${it}") }
  }
  if (selected.isEmpty()) {
    throw new GradleException("typecheck.sh: found no projects that run the Checker Framework in group ${group}.")
  }

  gradle.rootProject.tasks.register('typecheckCheckerFramework') {
    if (group == 'list') {
      doLast {
        selected.each { println "${groupOf(it)} ${it}:compileJava" }
      }
    } else {
      dependsOn(selected.collect { "${it}:compileJava" })
      println "Type-checking ${selected.size()} modules in group ${group}."
    }
  }
}
EOF

GRADLE_ARGS+=(-I "$INIT_SCRIPT" -PtypecheckGroup="$GROUP" -PtypecheckPart1="$(IFS=,; echo "${PART1[*]}")")
if [ "$GROUP" = list ]; then
  gradle_retry "60 300 0" "${GRADLE_ARGS[@]}" -q typecheckCheckerFramework
else
  # Dependencies are resolved as the compileJava tasks run.  A retry re-runs only the tasks that did
  # not succeed, so it retries once:  a longer sequence could exceed the CI job's time limit.
  gradle_retry "60 0" "${GRADLE_ARGS[@]}" --continue typecheckCheckerFramework
fi
