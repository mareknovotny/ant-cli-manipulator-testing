#!/usr/bin/env bash
#
# Invoke the ant-manipulation CLI against a single build file.
# Meant to be sourced, not executed.

# Non-standard JAVA_HOME locations to try before falling back to `java` on
# PATH. Add more candidates here as needed (e.g. per-OS GraalVM installs).
JAVA_CANDIDATES=(
    "/Library/Java/JavaVirtualMachines/graalvm-25.jdk/Contents/Home/bin/java"
)

resolve_java() {
    local candidate
    for candidate in "${JAVA_CANDIDATES[@]}"; do
        [ -x "$candidate" ] && { echo "$candidate"; return; }
    done
    echo "java"
}

# run_ant_manipulation <jar> <build_file> <deploy_version> <da_url> <token> <preview_flag>
# preview_flag is either "" (write mode) or "--preview".
run_ant_manipulation() {
    local jar=$1 build_file=$2 deploy_version=$3 da_url=$4 token=$5 preview=$6
    local java_bin
    java_bin="$(resolve_java)"

    echo ">> running ant-manipulation against $build_file ${preview:-(WRITE MODE)} ..." >&2
    "$java_bin" -jar "$jar" \
        -f "$build_file" \
        -DrestURL="$da_url" \
        -DrestMode=PERSISTENT \
        -DversionIncrementalSuffix=redhat \
        -Dmaven.asf.release.deploy.version="$deploy_version" \
        -DrestHeaders="Authorization:Bearer $token" \
        $preview
}
