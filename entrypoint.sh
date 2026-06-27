#!/usr/bin/env bash
# Custom wrapper for ghcr.io/ptero-eggs/games:arma3
#
# Optional Pterodactyl variables:
#   STEAM_WORKSHOP_COLLECTION_URL
#   STEAM_WORKSHOP_SERVERMODS_COLLECTION_URL
#
# Behaviour:
#   - Resolves Workshop collections through Steam's collection API.
#   - Adds normal collection items to MODIFICATIONS.
#   - Adds server-only collection items to SERVERMODS.
#   - Downloads all @<Workshop-ID> entries itself via SteamCMD.
#   - Exposes every Workshop item at /home/container/@<id>.
#   - Copies .bikey files to /home/container/keys.
#   - Converts known mod folders to absolute paths before invoking the
#     original Arma 3 entrypoint.

set -Eeuo pipefail

readonly SERVER_ROOT="${SERVER_ROOT:-/home/container}"
readonly WORKSHOP_APP_ID="${WORKSHOP_APP_ID:-107410}"
readonly STEAM_COLLECTION_API="${STEAM_COLLECTION_API:-https://api.steampowered.com/ISteamRemoteStorage/GetCollectionDetails/v1/}"

readonly MAX_COLLECTION_DEPTH="${MAX_COLLECTION_DEPTH:-8}"
readonly MAX_COLLECTION_ITEMS="${MAX_COLLECTION_ITEMS:-500}"

readonly STEAMCMD_ATTEMPTS="${STEAMCMD_ATTEMPTS:-5}"
readonly STEAMCMD_RETRY_DELAY="${STEAMCMD_RETRY_DELAY:-5}"

readonly UPSTREAM_ENTRYPOINT="${UPSTREAM_ENTRYPOINT:-/entrypoint-upstream.sh}"

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

trim_all_whitespace() {
    # Steam URLs and Workshop IDs cannot contain whitespace. This also treats
    # a Pterodactyl variable containing only spaces/newlines as unset.
    printf '%s' "$1" | tr -d '[:space:]'
}

extract_collection_id() {
    local value
    value="$(trim_all_whitespace "$1")"

    if [[ "$value" =~ ^[0-9]{5,20}$ ]]; then
        printf '%s\n' "$value"
        return 0
    fi

    if [[ "$value" =~ [\?\&]id=([0-9]{5,20})([\&\#]|$) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    die 'Collection value must be a numeric Steam Workshop collection ID or a URL containing ?id=<numeric-id>.'
}

fetch_collection_json() {
    local collection_id="$1"
    local response

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
    )" || die "Could not fetch Steam Workshop collection ${collection_id}. Ensure it is public and Steam's API is reachable."

    jq -e \
        '.response.collectiondetails | type == "array" and length == 1' \
        >/dev/null <<<"$response" \
        || die "Steam returned an unexpected response for collection ${collection_id}."

    local result
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

    (( depth <= MAX_COLLECTION_DEPTH )) \
        || die "Maximum nested collection depth (${MAX_COLLECTION_DEPTH}) exceeded."

    [[ -z "${RESOLVED_COLLECTIONS[$collection_id]:-}" ]] || return 0
    RESOLVED_COLLECTIONS["$collection_id"]=1

    local response
    response="$(fetch_collection_json "$collection_id")"

    local child_type
    local child_id

    while IFS=$'\t' read -r child_type child_id; do
        [[ "$child_id" =~ ^[0-9]{5,20}$ ]] || continue

        # Steam filetype 2 represents a nested Workshop collection.
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
    local joined=''

    IFS=';' read -r -a entries <<<"${current_value%;}"

    for entry in "${entries[@]}"; do
        entry="$(trim_all_whitespace "$entry")"
        [[ -n "$entry" ]] || continue

        # Normalise manually configured @<Workshop-ID> entries.
        if [[ "$entry" =~ ^@([0-9]{5,20})$ ]]; then
            entry="@${BASH_REMATCH[1]}"
        fi

        [[ -z "${seen_entries[$entry]:-}" ]] || continue

        seen_entries["$entry"]=1
        joined+="${entry};"
    done

    for id in "$@"; do
        [[ "$id" =~ ^[0-9]{5,20}$ ]] || continue

        entry="@${id}"

        [[ -z "${seen_entries[$entry]:-}" ]] || continue

        seen_entries["$entry"]=1
        joined+="${entry};"
    done

    printf -v "$variable_name" '%s' "$joined"
    export "$variable_name"
}

collect_workshop_ids_from_variable() {
    local variable_name="$1"
    local current_value="${!variable_name:-}"
    local -a entries=()

    local entry

    IFS=';' read -r -a entries <<<"${current_value%;}"

    for entry in "${entries[@]}"; do
        entry="$(trim_all_whitespace "$entry")"

        if [[ "$entry" =~ ^@([0-9]{5,20})$ ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
        fi
    done
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

    # SteamCMD can use a different Steam library path depending on image version.
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

expose_workshop_mod() {
    local item_id="$1"
    local source_dir="$2"

    local target_dir="${SERVER_ROOT}/@${item_id}"
    local resolved_target
    local resolved_source

    resolved_source="$(readlink -f "$source_dir")"

    # Eine echte, bereits funktionierende Root-Modinstallation beibehalten.
    if [[ -d "$target_dir/addons" && ! -L "$target_dir" ]]; then
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

    copy_bikeys "$source_dir"
}

download_and_expose_workshop_item() {
    local item_id="$1"
    local steamcmd

    steamcmd="$(steamcmd_binary)"

    [[ -n "${STEAM_USER:-}" && -n "${STEAM_PASS:-}" ]] \
        || die 'STEAM_USER and STEAM_PASS must be configured for Workshop downloads.'

    local attempt
    local source_dir

    for ((attempt = 1; attempt <= STEAMCMD_ATTEMPTS; attempt++)); do
        log "Downloading Workshop item ${item_id} (attempt ${attempt}/${STEAMCMD_ATTEMPTS})..."

        if HOME="$SERVER_ROOT" "$steamcmd" \
            +login "$STEAM_USER" "$STEAM_PASS" \
            +workshop_download_item "$WORKSHOP_APP_ID" "$item_id" validate \
            +quit; then

            source_dir="$(find_workshop_content_dir "$item_id" || true)"

            if [[ -n "$source_dir" && -d "$source_dir/addons" ]]; then
                expose_workshop_mod "$item_id" "$source_dir"
                log "Workshop item ${item_id} is ready at @${item_id}."
                return 0
            fi

            warn "SteamCMD reported success for ${item_id}, but no usable addons directory was found."
        fi

        if (( attempt < STEAMCMD_ATTEMPTS )); then
            warn "Workshop item ${item_id} is not ready; retrying in ${STEAMCMD_RETRY_DELAY}s."
            sleep "$STEAMCMD_RETRY_DELAY"
        fi
    done

    die "Could not download Workshop item ${item_id} after ${STEAMCMD_ATTEMPTS} attempt(s)."
}

normalise_mod_paths() {
    local variable_name="$1"
    local current_value="${!variable_name:-}"
    local -a entries=()

    local entry
    local joined=''

    IFS=';' read -r -a entries <<<"${current_value%;}"

    for entry in "${entries[@]}"; do
        entry="$(trim_all_whitespace "$entry")"
        [[ -n "$entry" ]] || continue

        # Relative mod folders in /home/container become absolute. Unknown
        # values remain untouched, so manually configured special paths survive.
        if [[ "$entry" != /* && -d "${SERVER_ROOT}/${entry}" ]]; then
            entry="${SERVER_ROOT}/${entry}"
        fi

        joined+="${entry};"
    done

    printf -v "$variable_name" '%s' "$joined"
    export "$variable_name"

    log "${variable_name} prepared: ${joined:-<empty>}"
}

main() {
    local client_collection="${STEAM_WORKSHOP_COLLECTION_URL:-}"
    local server_collection="${STEAM_WORKSHOP_SERVERMODS_COLLECTION_URL:-}"

    local collection_result

    local -a client_collection_ids=()
    local -a server_collection_ids=()
    local -a all_workshop_ids=()

    local -A seen_workshop_ids=()

    local item_id

    client_collection="$(trim_all_whitespace "$client_collection")"
    server_collection="$(trim_all_whitespace "$server_collection")"

    if [[ -n "$client_collection" ]]; then
        collection_result="$(resolve_collection_url "$client_collection")"
        mapfile -t client_collection_ids <<<"$collection_result"

        append_workshop_ids_to_variable \
            MODIFICATIONS \
            "${client_collection_ids[@]}"

        log "Added ${#client_collection_ids[@]} item(s) to MODIFICATIONS."
    else
        log 'No STEAM_WORKSHOP_COLLECTION_URL configured; MODIFICATIONS remains unchanged.'
    fi

    if [[ -n "$server_collection" ]]; then
        collection_result="$(resolve_collection_url "$server_collection")"
        mapfile -t server_collection_ids <<<"$collection_result"

        append_workshop_ids_to_variable \
            SERVERMODS \
            "${server_collection_ids[@]}"

        log "Added ${#server_collection_ids[@]} item(s) to SERVERMODS."
    else
        log 'No STEAM_WORKSHOP_SERVERMODS_COLLECTION_URL configured; SERVERMODS remains unchanged.'
    fi

    # Neben Collections auch manuell eingetragene @<Workshop-ID>-Mods behandeln.
    # OPTIONALMODS wird heruntergeladen, damit der Upstream-Entrypoint dessen
    # Signaturen/Keys weiterhin nutzen kann.
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

    for item_id in "${all_workshop_ids[@]}"; do
        download_and_expose_workshop_item "$item_id"
    done

    normalise_mod_paths MODIFICATIONS
    normalise_mod_paths SERVERMODS

    # Das Upstream-Image leitet normalerweise MODIFICATIONS nach CLIENT_MODS
    # ab. Der Export ist zusätzlich kompatibel mit Varianten, die CLIENT_MODS
    # direkt verwenden.
    export CLIENT_MODS="$MODIFICATIONS"

    exec "$UPSTREAM_ENTRYPOINT" "$@"
}

main "$@"
