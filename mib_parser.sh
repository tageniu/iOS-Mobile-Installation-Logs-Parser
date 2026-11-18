#!/bin/bash
# Bash 3.2+ port of mib_parser.sql.py. Requires the sqlite3 command-line tool.
# Usage: bash mib_parser.sh -o OUTPUT_DIR [LOG_FILE ...]
# Defaults to *.log.* in the current directory; refuses existing outputs.
# Creates mib.db, Apps_State/, Apps_Historical/, and System_State/.
# App state is inferred from the latest recognized event for each bundle.
set -euo pipefail

usage() {
    printf 'Usage: %s [-o OUTPUT_DIR] [--] [LOG_FILE ...]\n' "${0##*/}"
    printf 'With no files, reads *.log.* in the current directory. Outputs must not exist.\n'
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

# Quote all log-derived values as SQL string literals, including apostrophes.
sql_quote() {
    quoted=${1//\'/\'\'}
    quoted="'$quoted'"
}

emit_event() {
    local action=$1 bundle=$2 path=$3 value
    printf 'INSERT INTO dimm VALUES('
    for value in "$timestamp" "$action" "$bundle"; do
        sql_quote "$value"
        printf '%s,' "$quoted"
    done
    sql_quote "$path"
    printf '%s);\n' "$quoted"
}

# Container and delta events share bundle/path extraction and validation.
emit_path_event() {
    local action=$1 bundle_re=$2 path_re=$3 line=$4 location=$5 bundle
    [[ $line =~ $bundle_re ]] || die "Invalid $action event: $location"
    bundle=${BASH_REMATCH[1]}
    [[ $line =~ $path_re ]] || die "Missing $action path or versions: $location"
    emit_event "$action" "$bundle" "${BASH_REMATCH[1]}"
}

parse_logs() {
    local file line count=0 line_number month timestamp location
    local stamp_re='^[[:alpha:]]{3} ([[:alpha:]]{3}) +([0-9]{1,2}) ([0-9]{2}:[0-9]{2}:[0-9]{2}) ([0-9]{4}) \['
    local install_re=' for \((Placeholder:|Customer:|System:)?(.*)\)'
    local destroy_re='identifier (.*) at '
    local moved_re='for (.*) is now '
    local live_re='for (.*) at'
    local uninstall_re='Uninstalling identifier (.*)'
    local delta_re='Attempting Delta patch update of (.*) from'
    local path_re=' at (.*)$' delta_path_re=' from (.*)$'
    printf 'BEGIN;\nCREATE TABLE dimm(time_stamp TEXT, action TEXT, bundle_id TEXT, path TEXT);\n'
    for file in "$@"; do
        line_number=0
        while IFS= read -r line || [[ -n $line ]]; do
            count=$((count + 1))
            line_number=$((line_number + 1))
            location="$file:$line_number"
            line=${line%$'\r'}
            case $line in
                *'Install Successful for'* | \
                *'Destroying container with identifier'* | \
                *'Data container for'* | \
                *'Made container live for'* | \
                *'Uninstalling identifier '* | \
                *'main: Reboot detected'* | \
                *'Attempting Delta patch update of '*) ;;
                *) continue ;;
            esac
            [[ $line =~ $stamp_re ]] || die "Invalid event timestamp: $location"
            case ${BASH_REMATCH[1]} in
                Jan) month=01 ;; Feb) month=02 ;; Mar) month=03 ;;
                Apr) month=04 ;; May) month=05 ;; Jun) month=06 ;;
                Jul) month=07 ;; Aug) month=08 ;; Sep) month=09 ;;
                Oct) month=10 ;; Nov) month=11 ;; Dec) month=12 ;;
                *) die "Invalid month: $location" ;;
            esac
            printf -v timestamp '%s-%s-%02d %s' \
                "${BASH_REMATCH[4]}" "$month" \
                "$((10#${BASH_REMATCH[2]}))" "${BASH_REMATCH[3]}"
            if [[ $line == *'Install Successful for'* ]]; then
                [[ $line =~ $install_re ]] || die "Invalid install event: $location"
                emit_event 'Install successful' "${BASH_REMATCH[2]}" ''
            fi
            if [[ $line == *'Destroying container with identifier'* ]]; then
                emit_path_event 'Destroying container' "$destroy_re" "$path_re" "$line" "$location"
            fi
            if [[ $line == *'Data container for'* ]]; then
                emit_path_event 'Data container moved' "$moved_re" "$path_re" "$line" "$location"
            fi
            if [[ $line == *'Made container live for'* ]]; then
                emit_path_event 'Made container live' "$live_re" "$path_re" "$line" "$location"
            fi
            if [[ $line == *'Uninstalling identifier '* ]]; then
                [[ $line =~ $uninstall_re ]] || die "Invalid uninstall event: $location"
                emit_event 'Uninstalling identifier' "${BASH_REMATCH[1]}" ''
            fi
            if [[ $line == *'main: Reboot detected'* ]]; then
                emit_event 'Reboot detected' '' ''
            fi
            if [[ $line == *'Attempting Delta patch update of '* ]]; then
                emit_path_event 'Attempting Delta patch' "$delta_re" "$delta_path_re" "$line" "$location"
            fi
        done < "$file"
    done
    printf 'COMMIT;\n'
    printf '%s\n' "$count" > "$work/line_count"
}

query() {
    sqlite3 -batch -bail -noheader "$work/mib.db" "$1"
}

generate_reports() {
    local bundle historical=0 installed uninstalled system_events lines name
    # Earliest input row wins timestamp ties, matching Python/SQLite ordering.
    query "CREATE VIEW latest AS
        SELECT d.*, (SELECT min(rowid) FROM dimm WHERE bundle_id = d.bundle_id) AS first_seen
        FROM dimm d WHERE bundle_id != '' AND rowid = (
            SELECT rowid FROM dimm WHERE bundle_id = d.bundle_id
            ORDER BY time_stamp DESC, rowid ASC LIMIT 1);"
    query "SELECT bundle_id FROM latest
        WHERE action IN ('Destroying container', 'Uninstalling identifier')
        ORDER BY first_seen;" > "$work/Apps_State/UninstalledApps.txt"
    query "SELECT bundle_id FROM latest
        WHERE action NOT IN ('Destroying container', 'Uninstalling identifier')
        ORDER BY first_seen;" > "$work/Apps_State/InstalledApps.txt"
    query "SELECT bundle_id FROM dimm WHERE bundle_id != ''
        GROUP BY bundle_id ORDER BY min(rowid);" > "$work/bundles"
    while IFS= read -r bundle; do
        # Bundle identifiers become filenames, never paths outside the report folder.
        [[ $bundle != */* && $bundle != *$'\r'* ]] || die "Unsafe bundle identifier: $bundle"
        sql_quote "$bundle"
        query "SELECT time_stamp || ' ' || action || ' ' || bundle_id || ' ' || path
            FROM dimm WHERE bundle_id = $quoted ORDER BY time_stamp DESC, rowid ASC;" > "$work/Apps_Historical/$bundle.txt"
        historical=$((historical + 1))
    done < "$work/bundles"
    query "SELECT time_stamp || ' ' || action || ' ' || bundle_id || ' ' || path
        FROM dimm WHERE action = 'Reboot detected' ORDER BY time_stamp DESC, rowid ASC;" > "$work/System_State/SystemState.txt"
    query 'DROP VIEW latest;'
    installed=$(wc -l < "$work/Apps_State/InstalledApps.txt")
    uninstalled=$(wc -l < "$work/Apps_State/UninstalledApps.txt")
    system_events=$(wc -l < "$work/System_State/SystemState.txt")
    lines=$(cat "$work/line_count")
    for name in mib.db Apps_State Apps_Historical System_State; do
        mv -- "$work/$name" "$output/$name"
    done
    printf '\niOS Mobile Installation Logs Parser (Bash)\n\n'
    printf 'Logs processed: %d\nLines processed: %d\n\n' "$#" "$lines"
    printf 'Total apps: %d\nTotal installed apps: %d\nTotal uninstalled apps: %d\n' "$((installed + uninstalled))" "$installed" "$uninstalled"
    printf 'Total historical app reports: %d\nTotal system state events: %d\n' "$historical" "$system_events"
    printf 'Reports saved to: %s\n' "$output"
}

main() {
    # Bash dynamic scope shares this run's output paths and SQL quoting buffer
    # with helpers; parse_logs similarly provides timestamp to emit_event.
    local output=. work quoted file name
    while (($#)); do
        case $1 in
            -o|--output)
                (($# >= 2)) || die 'Missing output directory'
                output=$2
                shift 2
                ;;
            -h|--help) usage; exit 0 ;;
            --) shift; break ;;
            -*) die "Unknown option: $1" ;;
            *) break ;;
        esac
    done
    command -v sqlite3 >/dev/null 2>&1 || die 'sqlite3 is required'
    if (($# == 0)); then
        shopt -s nullglob
        set -- *.log.*
    fi
    (($#)) || die 'No input log files found'
    for file in "$@"; do
        [[ -f $file && -r $file ]] || die "Cannot read log: $file"
    done
    mkdir -p -- "$output"
    output=$(cd -- "$output" && pwd)
    for name in mib.db Apps_State Apps_Historical System_State; do
        [[ ! -e $output/$name && ! -L $output/$name ]] || die "Output already exists: $output/$name"
    done
    work=$(mktemp -d "$output/.mib-parser.XXXXXX")
    trap 'rm -rf -- "$work"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mkdir "$work/Apps_State" "$work/Apps_Historical" "$work/System_State"

    parse_logs "$@" | sqlite3 -batch -bail "$work/mib.db"
    generate_reports "$@"
    rm -rf -- "$work"
    trap - EXIT INT TERM
}

main "$@"
