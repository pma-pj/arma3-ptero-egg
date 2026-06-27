#!/usr/bin/env bash
# Resolve a Steam Workshop collection into @<workshop-id>; entries for the
# upstream ptero-eggs Arma 3 entrypoint.
#
# Environment variable:
#   STEAM_WORKSHOP_COLLECTION_URL
#     - optional; accepts a collection URL or its numeric published-file ID
#
# The upstream entrypoint receives the resulting list via MODIFICATIONS and
# remains responsible for downloading, updating, moving .bikey files and
# starting Arma 3.

set -Eeuo pipefail

readonly STEAM_COLLECTION_API='https://api.steampowered.com/ISteamRemoteStorage/GetCollectionDetails/v1/'
readonly MAX_COLLECTION_DEPTH="${MAX_COLLECTION_DEPTH:-8}"
readonly MAX_COLLECTION_ITEMS="${MAX_COLLECTION_ITEMS:-500}"

die() {
    echo "[COLLECTION_ERR] $*" >&2
    exit 1
}

warn() {
    echo "[COLLECTION_WARN] $*" >&2
}

extract_collection_id() {
    local value="${1//[[:space:]]/}"

    if [[ "$value" =~ ^[0-9]{5,20}$ ]]; then
        printf '%s\n' "$value"
        return 0
    fi

    if [[ "$value" =~ [\?\&]id=([0-9]{5,20})([\&\#]|$) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    die 'STEAM_WORKSHOP_COLLECTION_URL must be a Steam Workshop collection URL containing ?id=<numeric-id>, or just the numeric collection ID.'
}

fetch_collection() {
    local collection_id="$1"
    local response

    response="$({
        curl \
            --fail \
            --silent \
            --show-error \
            --location \
            --connect-timeout 10 \
            --max-time 45 \
            --retry 3 \
            --retry-delay 2 \
            --retry-all-errors \
            --request POST \
            --data-urlencode 'collectioncount=1' \
            --data-urlencode "publishedfileids[0]=${collection_id}" \
            "$STEAM_COLLECTION_API"
    } )" || die "Steam collection ${collection_id} could not be fetched. Check that it is public and that Steam's API is reachable."

    jq -e '.response.collectiondetails | type == "array" and length == 1' >/dev/null <<<"$response" \
        || die "Steam returned an unexpected response for collection ${collection_id}."

    local result
    result="$(jq -r '.response.collectiondetails[0].result // empty' <<<"$response")"
    [[ "$result" == '1' ]] \
        || die "Steam could not resolve collection ${collection_id} (result=${result:-missing})."

    printf '%s' "$response"
}

# Steam identifies nested collections with filetype 2. Normal Workshop items
# are emitted as leaf IDs. Recursion permits a collection to include another
# collection without forcing the panel user to paste several URLs.
declare -A visited_collections=()
declare -A seen_workshop_items=()
declare -a workshop_items=()

resolve_collection() {
    local collection_id="$1"
    local depth="$2"

    (( depth <= MAX_COLLECTION_DEPTH )) \
        || die "Maximum nested collection depth (${MAX_COLLECTION_DEPTH}) exceeded."

    [[ -z "${visited_collections[$collection_id]:-}" ]] || return 0
    visited_collections["$collection_id"]=1

    local response
    response="$(fetch_collection "$collection_id")"

    local child_type child_id
    while IFS=$'\t' read -r child_type child_id; do
        [[ "$child_id" =~ ^[0-9]{5,20}$ ]] || continue

        if [[ "$child_type" == '2' ]]; then
            echo "[COLLECTION] Resolving nested collection: ${child_id}"
            resolve_collection "$child_id" "$((depth + 1))"
            continue
        fi

        [[ -z "${seen_workshop_items[$child_id]:-}" ]] || continue
        seen_workshop_items["$child_id"]=1
        workshop_items+=("$child_id")

        (( ${#workshop_items[@]} <= MAX_COLLECTION_ITEMS )) \
            || die "Collection contains more than ${MAX_COLLECTION_ITEMS} unique Workshop items."
    done < <(
        jq -r '
            .response.collectiondetails[0].children[]?
            | "\(.filetype // 0)\t\(.publishedfileid // \"\")"
        ' <<<"$response"
    )
}

append_collection_to_modifications() {
    local collection_input="$1"
    local collection_id
    collection_id="$(extract_collection_id "$collection_input")"

    echo "[COLLECTION] Resolving Steam Workshop collection: ${collection_id}"
    resolve_collection "$collection_id" 0

    (( ${#workshop_items[@]} > 0 )) \
        || die "Collection ${collection_id} contains no Workshop items."

    local collection_modifications=''
    local item
    for item in "${workshop_items[@]}"; do
        collection_modifications+="@${item};"
    done

    # Preserve manually configured folders/IDs. The upstream image de-duplicates
    # the combined list before it downloads or loads any mod.
    if [[ -n "${MODIFICATIONS:-}" ]]; then
        MODIFICATIONS="${MODIFICATIONS%;};${collection_modifications}"
    else
        MODIFICATIONS="$collection_modifications"
    fi
    export MODIFICATIONS

    echo "[COLLECTION] Added ${#workshop_items[@]} Workshop item(s) to MODIFICATIONS."
}

if [[ -n "${STEAM_WORKSHOP_COLLECTION_URL:-}" ]]; then
    append_collection_to_modifications "$STEAM_WORKSHOP_COLLECTION_URL"
else
    echo '[COLLECTION] No STEAM_WORKSHOP_COLLECTION_URL configured; using the upstream mod configuration unchanged.'
fi

# Preserve the original CMD arguments as a defensive measure, even though the
# upstream image normally invokes this wrapper through its default CMD.
exec /entrypoint-upstream.sh "$@"
