#!/bin/sh
# parquet-java and Avro Java read what the writers wrote (ADR-0118 §6): each file the page writer's test leaves in
# out/parquet-written, beside the pyarrow fixture it came from, and each manifest the Avro test leaves in
# out/avro-written. Run in the package's directory after `ceesafec test`.
# usage: MVN=<maven> [MAVEN_REPO=<local repository>] tools/parquet_java_check.sh    (needs a JDK 17+ and python3)
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=$(pwd)/out
repo=${MAVEN_REPO:-$HOME/.m2/repository}
[ -d "$out/parquet-written" ] && [ -d "$out/avro-written" ] || { echo "FAIL no written files: run ceesafec test first"; exit 1; }
# The fixtures, from their hex in parquet_page_fixtures.cee.
rm -rf "$out/parquet-fixtures" && mkdir -p "$out/parquet-fixtures"
python3 -I - "$here/../src/s3/parquet_page_fixtures.cee" "$out/parquet-fixtures" <<'EOF'
import re, sys
source = open(sys.argv[1]).read()
for m in re.finditer(r"const PAGES_(\w+): \[StringView; \d+\] = \[(.*?)\];", source, re.S):
    if not m.group(1).endswith("EXPECTED"):
        with open("%s/%s.parquet" % (sys.argv[2], m.group(1)), "wb") as f:
            f.write(bytes.fromhex("".join(re.findall(r'"([0-9a-f]+)"', m.group(2)))))
EOF
java_dir="$here/parquet_java"
(cd "$java_dir" && "${MVN:-mvn}" -q -Dmaven.repo.local="$repo" compile dependency:build-classpath \
    -Dmdep.outputFile=target/cp.txt) || { echo "FAIL maven build"; exit 1; }
exec java --enable-native-access=ALL-UNNAMED -cp "$java_dir/target/classes:$(cat "$java_dir/target/cp.txt")" Check \
    "$out/parquet-written" "$out/parquet-fixtures" "$out/avro-written"
