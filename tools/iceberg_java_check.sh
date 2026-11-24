#!/bin/sh
# Iceberg Java's v3 table compacted here (ADR-0122 slice 6): builds tools/iceberg_java with Maven, then runs
# tools/iceberg_java_check.py against a `serve` it starts on PORT.
# usage: MVN=<maven> ICEBERG_PYTHON=<python with pyiceberg> [MAVEN_REPO=<repository>] tools/iceberg_java_check.sh \
#          COSMOSTORE PORT    (needs a JDK 17+)
set -e
here=$(cd "$(dirname "$0")" && pwd)
bin=$1
port=$2
repo=${MAVEN_REPO:-$HOME/.m2/repository}
(cd "$here/iceberg_java" && "${MVN:-mvn}" -q -Dmaven.repo.local="$repo" compile dependency:build-classpath \
    -Dmdep.outputFile=target/cp.txt) || { echo "FAIL maven build"; exit 1; }
work=$(mktemp -d)
export AWS_ACCESS_KEY_ID=AKIAJAVACHECK0000001 AWS_SECRET_ACCESS_KEY=java/secret/0123456789abcdefghijklmn
echo "$AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY" > "$work/credentials"
"$bin" serve "$work/store" "$port" "$work/credentials" localhost --tables-day-seconds 12 2>> "$work/serve.log" &
server=$!
i=0
while ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && [ $i -lt 120 ]; do sleep 0.5; i=$((i + 1)); done
status=0
"${ICEBERG_PYTHON:-python3}" -u -I "$here/iceberg_java_check.py" "http://127.0.0.1:$port" 12 \
    "$here/iceberg_java/target/classes:$(cat "$here/iceberg_java/target/cp.txt")" || status=$?
kill "$server" 2>/dev/null || true
wait "$server" 2>/dev/null || true
[ $status -eq 0 ] && rm -rf "$work" || echo "serve's log and store: $work"
exit $status
