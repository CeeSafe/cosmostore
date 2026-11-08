#!/bin/sh
# The AWS SDK for Java v2 against `cosmostore serve` (M3 SDK matrix): tools/sdk/java/Check.java, then fsck.
# usage: MVN=<maven> [MAVEN_REPO=<local repository>] tools/sdk/java.sh    (needs a JDK 17+; the SDK comes from Maven)
. "$(dirname "$0")/common.sh"
here=$(cd "$(dirname "$0")/java" && pwd)
repo=${MAVEN_REPO:-$HOME/.m2/repository}
(cd "$here" && "${MVN:-mvn}" -q -Dmaven.repo.local="$repo" compile dependency:build-classpath -Dmdep.outputFile=target/cp.txt) \
    || { fail "maven build"; finish "java"; }
java -cp "$here/target/classes:$(cat "$here/target/cp.txt")" Check || failed=1
check "no extents left" "$(ls "$work/store/extents" | wc -l | tr -d ' ')" 0
finish "java"
