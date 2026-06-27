#!/usr/bin/env bash
# Custom Arma 3 / Pterodactyl entrypoint.
#
# The script deliberately starts Arma directly. It does not delegate to the
# upstream entrypoint, because the upstream startup command quoting is the
# remaining source of the mod-loading problem in this deployment.
#
# Optional custom variables:
#   STEAM_WORKSHOP_COLLECTION_URL
#   STEAM_WORKSHOP_SERVERMODS_COLLECTION_URL
#   STEAMCMD_BATCH_SIZE            (default 50, hard maximum 50)
#   WORKSHOP_VALIDATE              (0 default; set 1 only for a full validate)
#
# Existing egg variables used:
#   STEAM_USER, STEAM_PASS, SERVER_PORT, SERVER_BINARY, UPDATE_SERVER,
#   DISABLE_MOD_UPDATES, STEAMCMD_ATTEMPTS, STEAMCMD_EXTRA_FLAGS,
#   VALIDATE_SERVER, MODIFICATIONS, SERVERMODS, OPTIONALMODS, STARTUP_PARAMS.

set -Eeuo pipefail

SERVER_ROOT="${SERVER_ROOT:-/home/container}"
SERVER_BINARY="${SERVER_BINARY:-arma3server_x64}"
SERVER_PORT="${SERVER_PORT:-2302}"
SERVER_CONFIG="${SERVER_CONFIG:-server.cfg}"
BASIC_CONFIG="${BASIC_CONFIG:-basic.cfg}"

STEAMCMD_APPID="${STEAMCMD_APPID:-233780}"
WORKSHOP_APP_ID="${WORKSHOP_APP_ID:-107410}"
STEAM_COLLECTION_API="${STEAM_COLLECTION_API:-https://api.steampowered.com/ISteamRemoteStorage/GetCollectionDetails/v1/}"

MAX_COLLECTION_DEPTH="${MAX_COLLECTION_DEPTH:-8}"
MAX_COLLECTION_ITEMS="${MAX_COLLECTION_ITEMS:-500}"
MAX_STEAMCMD_BATCH_SIZE=50

STEAMCMD_ATTEMPTS="${STEAMCMD_ATTEMPTS:-3}"
STEAMCMD_RETRY_DELAY="${STEAMCMD_RETRY_DELAY:-5}"
STEAMCMD_BATCH_SIZE="${STEAMCMD_BATCH_SIZE:-50}"
WORKSHOP_VALIDATE="${WORKSHOP_VALIDATE:-0}"

log() {
    printf '[COLLECTION] %s\n' "$*" >&2
}

warn() {
    printf '[COLLECTION_WARN] %s\n' "$*" >&2
}

die() {
    printf '[COLLECTION_ERR] %s\n' "$*" >&2
    exit 1
}

is_enabled() {
    case "${1:-0}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

trim() {
    local value="$1"

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    printf '%s' "$value"
}

validate_runtime_settings() {
    case "$SERVER_BINARY" in
        arma3server|arma3server_x64|arma3serverprofiling|arma3serverprofiling_x64)
            ;;
        *)
            die "SERVER_BINARY '${SERVER_BINARY}' is not an allowed Arma 3 server binary."
            ;;
    esac

    [[ "$SERVER_PORT" =~ ^[0-9]{1,5}$ ]] \
        || die 'SERVER_PORT must be a valid numeric port.'

    [[ "$STEAMCMD_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] \
        || die 'STEAMCMD_ATTEMPTS must be a positive integer.'

    [[ "$STEAMCMD_RETRY_DELAY" =~ ^[0-9]+$ ]] \
        || die 'STEAMCMD_RETRY_DELAY must be a non-negative integer.'

    [[ "$STEAMCMD_BATCH_SIZE" =~ ^[1-9][0-9]*$ ]] \
        || die 'STEAMCMD_BATCH_SIZE must be a positive integer.'

    [[ "$MAX_COLLECTION_DEPTH" =~ ^[1-9][0-9]*$ ]] \
        || die 'MAX_COLLECTION_DEPTH must be a positive integer.'

    [[ "$MAX_COLLECTION_ITEMS" =~ ^[1-9][0-9]*$ ]] \
        || die 'MAX_COLLECTION_ITEMS must be a positive integer.'

    if (( STEAMCMD_BATCH_SIZE > MAX_STEAMCMD_BATCH_SIZE )); then
        warn "STEAMCMD_BATCH_SIZE=${STEAMCMD_BATCH_SIZE} exceeds the hard limit of ${MAX_STEAMCMD_BATCH_SIZE}; using ${MAX_STEAMCMD_BATCH_SIZE}."
        STEAMCMD_BATCH_SIZE="$MAX_STEAMCMD_BATCH_SIZE"
    fi
}

require_steam_credentials() {
    [[ -n "${STEAM_USER:-}" && -n "${STEAM_PASS:-}" ]] \
        || die 'STEAM_USER and STEAM_PASS must be configured for SteamCMD operations.'
}

steamcmd_binary() {
    local candidate

    for candidate in \
        "${STEAMCMD_BIN:-}" \
        "${SERVER_ROOT}/steamcmd/steamcmd.sh" \
        "${SERVER_ROOT}/Steam/steamcmd.sh"; do

        if [[ -n "$candidate" && -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    die "SteamCMD not found. Expected ${SERVER_ROOT}/steamcmd/steamcmd.sh."
}

extract_collection_id() {
    local value
    value="$(trim "$1")"

    if [[ "$value" =~ ^[0-9]{5,20}$ ]]; then
        printf '%s\n' "$value"
        return 0
    fi

    if [[ "$value" =~ (^|[\?\&])id=([0-9]{5,20})($|[\&#]) ]]; then
        printf '%s\n' "${BASH_REMATCH[2]}"
        return 0
    fi

    die 'A collection value must be a numeric Steam Workshop collection ID or a URL containing ?id=<numeric-id>.'
}

fetch_collection_json() {
    local collection_id="$1"
    local response
    local result

    response="$(
        curl \
            --fail \
            --silent \
            --show-error \
            --location \
            --connect-timeout 15 \
            --max-time 60 \
            --retry 3 \
            --retry-delay 2 \
            --retry-all-errors \
            --request POST \
            --data-urlencode 'collectioncount=1' \
            --data-urlencode "publishedfileids[0]=${collection_id}" \
            "$STEAM_COLLECTION_API"
    )" || die "Could not fetch Steam Workshop collection ${collection_id}. Ensure the collection is public and Steam's API is reachable."

    jq -e \
        '.response.collectiondetails | type == "array" and length == 1' \
        >/dev/null <<<"$response" \
        || die "Steam returned an unexpected response for collection ${collection_id}."

    result="$(jq -r '.response.collectiondetails[0].result // empty' <<<"$response")"

    [[ "$result" == '1' ]] \
        || die "Steam could not resolve collection ${collection_id} (result=${result:-missing})."

    printf '%s' "$response"
}

declare -A RESOLVED_COLLECTIONS=()
declare -A RESOLVED_ITEMS=()
declare -a RESOLVED_ITEM_IDS=()

resolve_collection_tree() {
    local collection_id="$1"
    local depth="$2"
    local response
    local child_type
    local child_id

    (( depth <= MAX_COLLECTION_DEPTH )) \
        || die "Maximum nested collection depth (${MAX_COLLECTION_DEPTH}) exceeded."

    [[ -z "${RESOLVED_COLLECTIONS[$collection_id]:-}" ]] || return 0
    RESOLVED_COLLECTIONS["$collection_id"]=1

    response="$(fetch_collection_json "$collection_id")"

    while IFS=$'\t' read -r child_type child_id; do
        [[ "$child_id" =~ ^[0-9]{5,20}$ ]] || continue

        # Steam filetype 2 denotes a nested Steam Workshop collection.
        if [[ "$child_type" == '2' ]]; then
            log "Resolving nested Steam Workshop collection: ${child_id}"
            resolve_collection_tree "$child_id" "$((depth + 1))"
            continue
        fi

        [[ -z "${RESOLVED_ITEMS[$child_id]:-}" ]] || continue

        RESOLVED_ITEMS["$child_id"]=1
        RESOLVED_ITEM_IDS+=("$child_id")

        (( ${#RESOLVED_ITEM_IDS[@]} <= MAX_COLLECTION_ITEMS )) \
            || die "A configured collection contains more than ${MAX_COLLECTION_ITEMS} unique Workshop items."
    done < <(
        jq -r '
            .response.collectiondetails[0].children[]?
            | [(.filetype // 0), (.publishedfileid // "")]
            | @tsv
        ' <<<"$response"
    )
}

resolve_collection_url() {
    local collection_value="$1"
    local collection_id

    collection_id="$(extract_collection_id "$collection_value")"

    RESOLVED_COLLECTIONS=()
    RESOLVED_ITEMS=()
    RESOLVED_ITEM_IDS=()

    log "Resolving Steam Workshop collection: ${collection_id}"
    resolve_collection_tree "$collection_id" 0

    (( ${#RESOLVED_ITEM_IDS[@]} > 0 )) \
        || die "Collection ${collection_id} contains no Workshop items."

    printf '%s\n' "${RESOLVED_ITEM_IDS[@]}"
}

append_workshop_ids_to_variable() {
    local variable_name="$1"
    shift

    local current_value="${!variable_name:-}"
    local -a entries=()
    local -A seen_entries=()
    local entry
    local id
    local result=''

    IFS=';' read -r -a entries <<<"${current_value%;}"

    for entry in "${entries[@]}"; do
        entry="$(trim "$entry")"
        [[ -n "$entry" ]] || continue

        if [[ "$entry" =~ ^@([0-9]{5,20})$ ]]; then
            entry="@${BASH_REMATCH[1]}"
        fi

        [[ -z "${seen_entries[$entry]:-}" ]] || continue
        seen_entries["$entry"]=1
        result+="${entry};"
    done

    for id in "$@"; do
        [[ "$id" =~ ^[0-9]{5,20}$ ]] || continue

        entry="@${id}"

        [[ -z "${seen_entries[$entry]:-}" ]] || continue
        seen_entries["$entry"]=1
        result+="${entry};"
    done

    printf -v "$variable_name" '%s' "$result"
    export "$variable_name"
}

collect_workshop_ids_from_variable() {
    local variable_name="$1"
    local current_value="${!variable_name:-}"
    local -a entries=()
    local entry

    IFS=';' read -r -a entries <<<"${current_value%;}"

    for entry in "${entries[@]}"; do
        entry="$(trim "$entry")"

        if [[ "$entry" =~ ^@([0-9]{5,20})$ ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
        fi
    done
}

find_workshop_content_dir() {
    local item_id="$1"
    local candidate

    for candidate in \
        "${SERVER_ROOT}/steamcmd/steamapps/workshop/content/${WORKSHOP_APP_ID}/${item_id}" \
        "${SERVER_ROOT}/Steam/steamapps/workshop/content/${WORKSHOP_APP_ID}/${item_id}" \
        "${SERVER_ROOT}/steamapps/workshop/content/${WORKSHOP_APP_ID}/${item_id}"; do

        if [[ -d "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    candidate="$(
        find \
            "$SERVER_ROOT" \
            -type d \
            -path "*/steamapps/workshop/content/${WORKSHOP_APP_ID}/${item_id}" \
            -print \
            -quit \
            2>/dev/null || true
    )"

    if [[ -n "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    return 1
}

copy_bikeys() {
    local mod_dir="$1"
    local keys_dir="${SERVER_ROOT}/keys"
    local key_file

    mkdir -p "$keys_dir"

    while IFS= read -r -d '' key_file; do
        cp -f "$key_file" "$keys_dir/"
    done < <(
        find "$mod_dir" -type f -iname '*.bikey' -print0 2>/dev/null
    )
}

ensure_workshop_meta() {
    local item_id="$1"
    local mod_dir="$2"
    local meta_file="${mod_dir}/meta.cpp"

    if [[ -f "$meta_file" ]] \
        && grep -Eq "^[[:space:]]*publishedid[[:space:]]*=[[:space:]]*${item_id}[[:space:]]*;" "$meta_file"; then
        return 0
    fi

    cat > "$meta_file" <<EOF
protocol = 1;
publishedid = ${item_id};
EOF
}

expose_workshop_mod() {
    local item_id="$1"
    local source_dir="$2"
    local target_dir="${SERVER_ROOT}/@${item_id}"
    local resolved_source
    local resolved_target

    resolved_source="$(readlink -f "$source_dir")"

    if [[ -d "$target_dir/addons" && ! -L "$target_dir" ]]; then
        ensure_workshop_meta "$item_id" "$target_dir"
        copy_bikeys "$target_dir"
        return 0
    fi

    if [[ -L "$target_dir" ]]; then
        resolved_target="$(readlink -f "$target_dir" 2>/dev/null || true)"

        if [[ "$resolved_target" != "$resolved_source" ]]; then
            rm -f "$target_dir"
        fi
    elif [[ -e "$target_dir" ]]; then
        rm -rf "$target_dir"
    fi

    if [[ ! -e "$target_dir" ]]; then
        ln -s "$source_dir" "$target_dir"
    fi

    [[ -d "$target_dir/addons" ]] \
        || die "Workshop item ${item_id} was downloaded, but ${target_dir}/addons is missing."

    ensure_workshop_meta "$item_id" "$target_dir"
    copy_bikeys "$source_dir"
}

steamcmd_update_server() {
    local steamcmd
    local -a command=()
    local -a extra_flags=()

    is_enabled "${UPDATE_SERVER:-1}" || {
        log 'UPDATE_SERVER is disabled; skipping Arma 3 Dedicated Server update.'
        return 0
    }

    require_steam_credentials
    steamcmd="$(steamcmd_binary)"

    read -r -a extra_flags <<<"${STEAMCMD_EXTRA_FLAGS:-}"

    command=(
        "$steamcmd"
        +force_install_dir "$SERVER_ROOT"
        +login "$STEAM_USER" "$STEAM_PASS"
        +app_update "$STEAMCMD_APPID"
    )

    if (( ${#extra_flags[@]} > 0 )); then
        command+=("${extra_flags[@]}")
    fi

    if is_enabled "${VALIDATE_SERVER:-0}"; then
        command+=(validate)
    fi

    command+=(+quit)

    log "Checking for Arma 3 Dedicated Server updates with App ID: ${STEAMCMD_APPID}."

    HOME="$SERVER_ROOT" "${command[@]}" \
        || die 'Arma 3 Dedicated Server update failed.'
}

download_workshop_batch() {
    local steamcmd="$1"
    shift

    local -a item_ids=("$@")
    local -a command=()
    local item_id

    (( ${#item_ids[@]} > 0 )) || return 0

    command=(
        "$steamcmd"
        +login "$STEAM_USER" "$STEAM_PASS"
    )

    for item_id in "${item_ids[@]}"; do
        command+=(
            +workshop_download_item
            "$WORKSHOP_APP_ID"
            "$item_id"
        )

        if is_enabled "$WORKSHOP_VALIDATE"; then
            command+=(validate)
        fi
    done

    command+=(+quit)

    HOME="$SERVER_ROOT" "${command[@]}"
}

download_workshop_item_with_retries() {
    local item_id="$1"
    local steamcmd
    local attempt
    local source_dir
    local -a command=()

    require_steam_credentials
    steamcmd="$(steamcmd_binary)"

    for ((attempt = 1; attempt <= STEAMCMD_ATTEMPTS; attempt++)); do
        log "Retrying Workshop item ${item_id} individually (attempt ${attempt}/${STEAMCMD_ATTEMPTS})."

        command=(
            "$steamcmd"
            +login "$STEAM_USER" "$STEAM_PASS"
            +workshop_download_item "$WORKSHOP_APP_ID" "$item_id"
        )

        # A retry validates incomplete or corrupt content regardless of the
        # normal WORKSHOP_VALIDATE setting.
        command+=(validate +quit)

        if HOME="$SERVER_ROOT" "${command[@]}"; then
            source_dir="$(find_workshop_content_dir "$item_id" || true)"

            if [[ -n "$source_dir" && -d "$source_dir/addons" ]]; then
                expose_workshop_mod "$item_id" "$source_dir"
                log "Workshop item ${item_id} is ready at @${item_id}."
                return 0
            fi
        fi

        if (( attempt < STEAMCMD_ATTEMPTS )); then
            warn "Workshop item ${item_id} is not ready; retrying in ${STEAMCMD_RETRY_DELAY}s."
            sleep "$STEAMCMD_RETRY_DELAY"
        fi
    done

    die "Could not prepare Workshop item ${item_id} after ${STEAMCMD_ATTEMPTS} attempt(s)."
}

prepare_workshop_items() {
    local -a all_items=("$@")
    local -a batch=()
    local -a failed_items=()
    local item_id
    local source_dir
    local start_index=0
    local total_items="${#all_items[@]}"
    local batch_number=0
    local steamcmd

    (( total_items > 0 )) || return 0

    if is_enabled "${DISABLE_MOD_UPDATES:-0}"; then
        log 'DISABLE_MOD_UPDATES is enabled; using only already downloaded Workshop items.'
    else
        require_steam_credentials
        steamcmd="$(steamcmd_binary)"

        while (( start_index < total_items )); do
            batch=("${all_items[@]:start_index:STEAMCMD_BATCH_SIZE}")
            batch_number=$((batch_number + 1))

            log "Downloading ${#batch[@]} Workshop item(s) in SteamCMD batch ${batch_number} (maximum ${MAX_STEAMCMD_BATCH_SIZE} per session)."

            if ! download_workshop_batch "$steamcmd" "${batch[@]}"; then
                warn "SteamCMD reported at least one failed operation in batch ${batch_number}; checking individual item states."
            fi

            start_index=$((start_index + ${#batch[@]}))
        done
    fi

    for item_id in "${all_items[@]}"; do
        source_dir="$(find_workshop_content_dir "$item_id" || true)"

        if [[ -n "$source_dir" && -d "$source_dir/addons" ]]; then
            expose_workshop_mod "$item_id" "$source_dir"
            log "Workshop item ${item_id} is ready at @${item_id}."
        else
            failed_items+=("$item_id")
        fi
    done

    if (( ${#failed_items[@]} > 0 )); then
        if is_enabled "${DISABLE_MOD_UPDATES:-0}"; then
            die "Workshop updates are disabled, but ${#failed_items[@]} required item(s) are missing. Set DISABLE_MOD_UPDATES=0 for one start."
        fi

        for item_id in "${failed_items[@]}"; do
            download_workshop_item_with_retries "$item_id"
        done
    fi
}

build_mod_paths() {
    local source_variable="$1"
    local target_array_name="$2"
    local current_value="${!source_variable:-}"
    local -a entries=()
    local -a normal_entries=()
    local -a cba_entries=()
    local -A seen_paths=()
    local entry
    local full_path
    local -n target_array="$target_array_name"

    target_array=()

    IFS=';' read -r -a entries <<<"${current_value%;}"

    for entry in "${entries[@]}"; do
        entry="$(trim "$entry")"
        [[ -n "$entry" ]] || continue

        if [[ "$entry" == /* ]]; then
            full_path="$entry"
        else
            full_path="${SERVER_ROOT}/${entry}"
        fi

        if [[ ! -d "$full_path" ]]; then
            warn "Configured mod path does not exist and will be skipped: ${full_path}"
            continue
        fi

        if [[ ! -d "$full_path/addons" ]]; then
            warn "Configured mod path has no addons directory and will be skipped: ${full_path}"
            continue
        fi

        [[ -z "${seen_paths[$full_path]:-}" ]] || continue
        seen_paths["$full_path"]=1

        # CBA_A3 is a common hard dependency and should load before dependent
        # gameplay mods. It is harmless when absent.
        if [[ "$full_path" == "${SERVER_ROOT}/@450814997" ]]; then
            cba_entries+=("$full_path")
        else
            normal_entries+=("$full_path")
        fi
    done

    target_array=("${cba_entries[@]}" "${normal_entries[@]}")
}

join_mod_paths() {
    local array_name="$1"
    local -n paths="$array_name"
    local joined=''
    local path

    for path in "${paths[@]}"; do
        if [[ -n "$joined" ]]; then
            # Linux-Arma benötigt den Backslash als Teil des Arguments.
            joined+='\;'
        fi

        joined+="$path"
    done

    printf '%s' "$joined"
}

parse_startup_parameters() {
    local raw_parameters="${STARTUP_PARAMS:--noLogs}"
    local -n target_array="$1"

    target_array=()

    # The official egg treats this whole field as one quoted argument. Here it
    # is intentionally split into individual CLI arguments, so
    # "-noLogs -autoInit" becomes two parameters.
    read -r -a target_array <<<"$raw_parameters"
}

print_command() {
    local argument

    printf '[STARTUP] Executing:' >&2
    for argument in "$@"; do
        printf ' %q' "$argument" >&2
    done
    printf '\n' >&2
}

start_arma_server() {
    local -a client_mod_paths=()
    local -a server_mod_paths=()
    local -a extra_parameters=()
    local -a command=()
    local client_mod_argument
    local server_mod_argument

    build_mod_paths MODIFICATIONS client_mod_paths
    build_mod_paths SERVERMODS server_mod_paths

    client_mod_argument="$(join_mod_paths client_mod_paths)"
    server_mod_argument="$(join_mod_paths server_mod_paths)"

    log "CLIENT MODS ready: ${#client_mod_paths[@]}"
    log "SERVER MODS ready: ${#server_mod_paths[@]}"

    parse_startup_parameters extra_parameters

    command=(
        "./${SERVER_BINARY}"
        '-ip=0.0.0.0'
        "-port=${SERVER_PORT}"
        '-profiles=./serverprofile'
        '-bepath=./'
        "-cfg=${BASIC_CONFIG}"
        "-config=${SERVER_CONFIG}"
    )

    if [[ -n "$client_mod_argument" ]]; then
        command+=("-mod=${client_mod_argument}")
    fi

    if [[ -n "$server_mod_argument" ]]; then
        command+=("-serverMod=${server_mod_argument}")
    fi

    command+=("${extra_parameters[@]}")

    print_command "${command[@]}"

    exec "${command[@]}"
}

main() {
    local client_collection
    local server_collection
    local collection_result
    local item_id

    local -a client_collection_ids=()
    local -a server_collection_ids=()
    local -a all_workshop_ids=()

    local -A seen_workshop_ids=()

    validate_runtime_settings

    mkdir -p "${SERVER_ROOT}/keys" "${SERVER_ROOT}/serverprofile"
    cd "$SERVER_ROOT"

    client_collection="$(trim "${STEAM_WORKSHOP_COLLECTION_URL:-}")"
    server_collection="$(trim "${STEAM_WORKSHOP_SERVERMODS_COLLECTION_URL:-}")"

    if [[ -n "$client_collection" ]]; then
        collection_result="$(resolve_collection_url "$client_collection")"
        mapfile -t client_collection_ids <<<"$collection_result"

        append_workshop_ids_to_variable MODIFICATIONS "${client_collection_ids[@]}"

        log "Added ${#client_collection_ids[@]} item(s) to MODIFICATIONS."
    else
        log 'No STEAM_WORKSHOP_COLLECTION_URL configured; MODIFICATIONS remains unchanged.'
    fi

    if [[ -n "$server_collection" ]]; then
        collection_result="$(resolve_collection_url "$server_collection")"
        mapfile -t server_collection_ids <<<"$collection_result"

        append_workshop_ids_to_variable SERVERMODS "${server_collection_ids[@]}"

        log "Added ${#server_collection_ids[@]} item(s) to SERVERMODS."
    else
        log 'No STEAM_WORKSHOP_SERVERMODS_COLLECTION_URL configured; SERVERMODS remains unchanged.'
    fi

    while IFS= read -r item_id; do
        [[ "$item_id" =~ ^[0-9]{5,20}$ ]] || continue
        [[ -z "${seen_workshop_ids[$item_id]:-}" ]] || continue

        seen_workshop_ids["$item_id"]=1
        all_workshop_ids+=("$item_id")
    done < <(
        collect_workshop_ids_from_variable MODIFICATIONS
        collect_workshop_ids_from_variable SERVERMODS
        collect_workshop_ids_from_variable OPTIONALMODS
    )

    steamcmd_update_server
    prepare_workshop_items "${all_workshop_ids[@]}"
    start_arma_server
}

main "$@"
