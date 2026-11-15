#!/usr/bin/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Share Git Sync
#
# Syncs folders of a (private) Git repository into /share:
#   - files in the new commit are written (repository wins, warning if a file
#     was changed locally or existed before without being managed)
#   - files that were synced last time but are no longer in the repository
#     are deleted (empty parent folders are removed)
#   - all other files are never touched
# If fetching the repository fails, nothing is changed.
# ==============================================================================
set -e

REPOSITORY=$(bashio::config 'repository')
BRANCH=$(bashio::config 'branch')
DRY_RUN=$(bashio::config 'dry_run')

SSH_DIR=/data/ssh
SSH_KEY="${SSH_DIR}/id_ed25519"
REPO_DIR=/data/repo
STATE_DIR=/data/state

# ------------------------------------------------------------------------------
# SSH deploy key (generated once, stored in /data, never leaves Home Assistant)
# ------------------------------------------------------------------------------
if [[ ! -f "${SSH_KEY}" ]]; then
    bashio::log.info "Generating SSH deploy key..."
    mkdir -p "${SSH_DIR}"
    chmod 700 "${SSH_DIR}"
    ssh-keygen -q -t ed25519 -N "" -C "home-assistant-share-git-sync" -f "${SSH_KEY}"
fi

export GIT_SSH_COMMAND="ssh -i ${SSH_KEY} -o IdentitiesOnly=yes -o UserKnownHostsFile=${SSH_DIR}/known_hosts -o StrictHostKeyChecking=accept-new"

print_deploy_key() {
    bashio::log.info "Add this public key as read-only deploy key to your repository"
    bashio::log.info "(GitHub: Settings -> Deploy keys -> Add deploy key):"
    bashio::log.info "$(cat "${SSH_KEY}.pub")"
}

if bashio::var.is_empty "${REPOSITORY}"; then
    print_deploy_key
    bashio::exit.nok "Option 'repository' is not set. Nothing was changed."
fi

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

# Strip leading/trailing slashes, "." => "" ; fails on ".." components
normalize_path() {
    local p="$1" part
    p="${p#/}"
    p="${p%/}"
    [[ "${p}" == "." ]] && p=""
    IFS='/' read -ra parts <<< "${p}"
    for part in "${parts[@]}"; do
        [[ "${part}" == ".." ]] && return 1
    done
    echo "${p}"
}

# Accepts the full slug or the slug without repository prefix
# (e.g. "nginx_proxy_custom" -> "1a2b3c4d_nginx_proxy_custom").
resolve_slug() {
    local wanted="$1" slugs matches
    slugs=$(bashio::api.supervisor GET "/addons" false ".addons[].slug") || return 1
    if grep -qx -- "${wanted}" <<< "${slugs}"; then
        echo "${wanted}"
        return 0
    fi
    matches=$(grep -- "_${wanted}\$" <<< "${slugs}" || true)
    if [[ -n "${matches}" && $(wc -l <<< "${matches}") -eq 1 ]]; then
        echo "${matches}"
        return 0
    fi
    return 1
}

file_sha() {
    sha256sum "$1" | cut -d' ' -f1
}

# Remove empty folders from $1 upwards, but never $2 (target root) or above
remove_empty_parents() {
    local dir="$1" root="$2"
    while [[ "${dir}" == "${root}/"* ]]; do
        rmdir "${dir}" 2> /dev/null || break
        bashio::log.info "  removed empty folder ${dir}"
        dir=$(dirname "${dir}")
    done
}

dry() {
    bashio::var.true "${DRY_RUN}"
}

# ------------------------------------------------------------------------------
# Fetch repository - any error here aborts without touching /share
# ------------------------------------------------------------------------------
if [[ ! -d "${REPO_DIR}/.git" ]]; then
    git init -q "${REPO_DIR}"
    git -C "${REPO_DIR}" remote add origin "${REPOSITORY}"
fi
git -C "${REPO_DIR}" remote set-url origin "${REPOSITORY}"

bashio::log.info "Fetching ${REPOSITORY} (${BRANCH})..."
if ! git -C "${REPO_DIR}" fetch -q origin "+refs/heads/${BRANCH}:refs/remotes/origin/${BRANCH}"; then
    print_deploy_key
    bashio::exit.nok "Could not fetch repository/branch. Nothing was changed."
fi

COMMIT=$(git -C "${REPO_DIR}" rev-parse "refs/remotes/origin/${BRANCH}")
if ! git -C "${REPO_DIR}" checkout -q --force --detach "${COMMIT}"; then
    bashio::exit.nok "Could not check out ${COMMIT}. Nothing was changed."
fi
COMMIT_INFO=$(git -C "${REPO_DIR}" log -1 --format='%h %s')
bashio::log.info "Repository at ${COMMIT_INFO}"
dry && bashio::log.warning "DRY RUN - nothing will be changed."

# ------------------------------------------------------------------------------
# Validate all mappings first - any error aborts without touching /share
# ------------------------------------------------------------------------------
OPTIONS=/data/options.json
TREE_DIR=$(mktemp -d)
MAPPING_COUNT=$(jq -r '.mappings | length' "${OPTIONS}")
declare -a M_SOURCE M_TARGET M_SLUG

for ((i = 0; i < MAPPING_COUNT; i++)); do
    raw_source=$(jq -r ".mappings[${i}].source // \"\"" "${OPTIONS}")
    raw_target=$(jq -r ".mappings[${i}].target // \"\"" "${OPTIONS}")
    restart=$(jq -r ".mappings[${i}].restart_addon // \"\"" "${OPTIONS}")

    source=$(normalize_path "${raw_source}") \
        || bashio::exit.nok "Mapping $((i + 1)): invalid source '${raw_source}'. Nothing was changed."
    target=$(normalize_path "${raw_target}") \
        || bashio::exit.nok "Mapping $((i + 1)): invalid target '${raw_target}'. Nothing was changed."

    if [[ -n "${source}" ]] \
        && [[ "$(git -C "${REPO_DIR}" cat-file -t "${COMMIT}:${source}" 2> /dev/null)" != "tree" ]]; then
        bashio::exit.nok "Mapping $((i + 1)): folder '${source}' not found in repository. Nothing was changed."
    fi

    slug=""
    if bashio::var.has_value "${restart}"; then
        slug=$(resolve_slug "${restart}") \
            || bashio::exit.nok "Mapping $((i + 1)): add-on '${restart}' not found (or ambiguous). Nothing was changed."
    fi

    tree="${COMMIT}"
    [[ -n "${source}" ]] && tree="${COMMIT}:${source}"
    if ! git -C "${REPO_DIR}" ls-tree -r -z "${tree}" > "${TREE_DIR}/${i}"; then
        bashio::exit.nok "Mapping $((i + 1)): could not list files of '${source}'. Nothing was changed."
    fi

    M_SOURCE[i]="${source}"
    M_TARGET[i]="${target}"
    M_SLUG[i]="${slug}"
done

# ------------------------------------------------------------------------------
# Sync
# ------------------------------------------------------------------------------
mkdir -p "${STATE_DIR}"
declare -A RESTART=()
ERRORS=0

for ((i = 0; i < MAPPING_COUNT; i++)); do
    source="${M_SOURCE[i]}"
    target="${M_TARGET[i]}"
    src_dir="${REPO_DIR}${source:+/${source}}"
    tgt_dir="/share${target:+/${target}}"
    state_file="${STATE_DIR}/$(echo -n "${source}|${target}" | sha1sum | cut -d' ' -f1).list"
    bashio::log.info "Mapping $((i + 1)): ${source:-<repository root>} -> ${tgt_dir}"

    # Files of the last sync: OLD[path]=sha256
    declare -A OLD=()
    if [[ -f "${state_file}" ]]; then
        while IFS=$'\t' read -r sha path; do
            OLD["${path}"]="${sha}"
        done < "${state_file}"
    else
        bashio::log.info "  first sync of this mapping - nothing will be deleted"
    fi

    # Files of the new commit: NEW[path]=mode
    declare -A NEW=()
    while IFS= read -r -d '' entry; do
        meta="${entry%%$'\t'*}"
        path="${entry#*$'\t'}"
        read -r mode type _ <<< "${meta}"
        if [[ "${type}" != "blob" || "${mode}" == "120000" ]]; then
            bashio::log.warning "  skipping ${path} (symlink/submodule not supported)"
            continue
        fi
        if [[ "${path}" == *$'\n'* || "${path}" == *$'\t'* ]]; then
            bashio::log.warning "  skipping file with tab/newline in its name"
            continue
        fi
        NEW["${path}"]="${mode}"
    done < "${TREE_DIR}/${i}"

    changed=0
    new_state=""

    # --- write new/changed files ---
    for path in "${!NEW[@]}"; do
        src_file="${src_dir}/${path}"
        dest="${tgt_dir}/${path}"
        new_sha=$(file_sha "${src_file}")
        perm=644
        [[ "${NEW[${path}]}" == "100755" ]] && perm=755

        if [[ -e "${dest}" && ! -f "${dest}" ]]; then
            bashio::log.error "  ${dest} exists but is not a file - skipped"
            ERRORS=$((ERRORS + 1))
            continue
        fi

        if [[ -f "${dest}" ]]; then
            cur_sha=$(file_sha "${dest}")
            if [[ "${cur_sha}" == "${new_sha}" ]]; then
                new_state+="${new_sha}"$'\t'"${path}"$'\n'
                continue
            fi
            if [[ -v OLD["${path}"] ]]; then
                if [[ "${cur_sha}" != "${OLD[${path}]}" ]]; then
                    bashio::log.warning "  ${dest} was changed locally - overwritten with repository version"
                fi
                bashio::log.info "  update ${dest}"
            else
                bashio::log.warning "  ${dest} already existed (not synced before) - overwritten with repository version"
            fi
        else
            bashio::log.info "  add ${dest}"
        fi

        if ! dry; then
            if ! mkdir -p "$(dirname "${dest}")" \
                || ! cp "${src_file}" "${dest}.gitsync.tmp" \
                || ! chmod "${perm}" "${dest}.gitsync.tmp" \
                || ! mv -f "${dest}.gitsync.tmp" "${dest}"; then
                rm -f "${dest}.gitsync.tmp"
                bashio::log.error "  could not write ${dest}"
                ERRORS=$((ERRORS + 1))
                continue
            fi
        fi
        new_state+="${new_sha}"$'\t'"${path}"$'\n'
        changed=1
    done

    # --- delete files that were synced before but are gone from the repository ---
    for path in "${!OLD[@]}"; do
        [[ -v NEW["${path}"] ]] && continue
        dest="${tgt_dir}/${path}"
        if [[ ! -f "${dest}" ]]; then
            continue
        fi
        if [[ "$(file_sha "${dest}")" != "${OLD[${path}]}" ]]; then
            bashio::log.warning "  ${dest} was changed locally - deleted anyway (removed from repository)"
        fi
        bashio::log.info "  delete ${dest}"
        if ! dry; then
            if ! rm -f "${dest}"; then
                bashio::log.error "  could not delete ${dest}"
                ERRORS=$((ERRORS + 1))
                new_state+="${OLD[${path}]}"$'\t'"${path}"$'\n'
                continue
            fi
            remove_empty_parents "$(dirname "${dest}")" "${tgt_dir}"
        fi
        changed=1
    done

    if [[ "${changed}" -eq 0 ]]; then
        bashio::log.info "  up to date"
    fi

    if ! dry; then
        printf '%s' "${new_state}" > "${state_file}.tmp"
        mv -f "${state_file}.tmp" "${state_file}"
        if [[ "${changed}" -eq 1 && -n "${M_SLUG[i]}" ]]; then
            RESTART["${M_SLUG[i]}"]=1
        fi
    fi

    unset OLD NEW
done

# ------------------------------------------------------------------------------
# Restart add-ons whose files changed
# ------------------------------------------------------------------------------
for slug in "${!RESTART[@]}"; do
    bashio::log.info "Restarting add-on ${slug}..."
    if ! bashio::api.supervisor POST "/addons/${slug}/restart" > /dev/null; then
        bashio::log.error "Restart of ${slug} failed."
        ERRORS=$((ERRORS + 1))
    fi
done

if [[ "${ERRORS}" -gt 0 ]]; then
    bashio::exit.nok "Finished with ${ERRORS} error(s), see log above."
fi
bashio::log.info "Sync of ${COMMIT_INFO} finished."
