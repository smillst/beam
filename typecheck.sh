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

# Shell glob patterns, matched against Gradle project paths.  part1 is the Dataflow runner and the
# chain of modules it depends on (:sdks:java:core, :sdks:java:io:google-cloud-platform), which must
# be type-checked one after another and so bounds the time of any group that contains them.  With
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

GRADLE_ARGS=(-PcfVersion=local --console=plain)

# Prints the path of every project that runs the Checker Framework, one per line.
list_cf_projects() {
  local init_script
  init_script="$(mktemp -t beam-list-cf-projects.XXXXXX)"
  cat > "$init_script" << 'EOF'
allprojects {
  afterEvaluate { p ->
    if (p.plugins.hasPlugin('org.checkerframework')
        && !p.extensions.getByName('checkerFramework').skipCheckerFramework.get()) {
      println "CF-PROJECT ${p.path}"
    }
  }
}
EOF
  ./gradlew "${GRADLE_ARGS[@]}" -q -I "$init_script" help | sed -n 's/^CF-PROJECT //p' | sort
  rm -f "$init_script"
}

# Returns 0 if project path $1 matches any of the remaining arguments, which are glob patterns.
matches_any() {
  local project="$1"
  shift
  local pattern
  for pattern in "$@"; do
    # shellcheck disable=SC2053 # $pattern is intentionally unquoted so that it is a glob.
    if [[ "$project" == $pattern ]]; then
      return 0
    fi
  done
  return 1
}

# Prints the group (part1 or part2) that contains project path $1.
group_of() {
  if matches_any "$1" "${PART1[@]}"; then
    echo part1
  else
    echo part2
  fi
}

PROJECTS=()
while IFS= read -r project; do
  PROJECTS+=("$project")
done < <(list_cf_projects)
if [ ${#PROJECTS[@]} -eq 0 ]; then
  echo "$0: found no projects that run the Checker Framework." >&2
  exit 1
fi

if [ "$GROUP" = list ]; then
  for project in "${PROJECTS[@]}"; do
    echo "$(group_of "$project") $project:compileJava"
  done
  exit 0
fi

TASKS=()
for project in "${PROJECTS[@]}"; do
  if [ "$GROUP" = all ] || [ "$(group_of "$project")" = "$GROUP" ]; then
    TASKS+=("$project:compileJava")
  fi
done

echo "Type-checking ${#TASKS[@]} modules in group $GROUP."
./gradlew "${GRADLE_ARGS[@]}" --continue "${TASKS[@]}"
