#!/usr/bin/env bash
#
# deploy.sh — interactive helper for SynologyDSManager maintainers.
#
# Run from the repo root:  ./deploy.sh
# Options are single-key; no Enter required.
#
#   p   Pull `main` from origin into local `main`; offers to stash /
#       discard / cancel if the working tree has uncommitted changes
#   o   Open the Xcode project
#   s   Configure code signing (creates Signing.local.xcconfig from template)
#   i   Build Debug and install to /Applications (local-testing flow;
#       Apple-Development signed, trusted by Gatekeeper on this Mac)
#   d   Build Release and create a distributable DMG (optionally notarised;
#       Developer-ID signed — needs notarisation for Safari extensions)
#   q   Quit
#
# Requires macOS with Xcode command-line tools installed. The build/install/DMG
# options also require a filled-in `Signing.local.xcconfig` with your Apple
# Developer Team ID — use the `s` option to set it up the first time.
#
set -euo pipefail

# Must run from the repo root (where this script lives).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ----- Constants -----------------------------------------------------------
readonly PROJECT="SynologyDSManager.xcodeproj"
readonly SCHEME="SynologyDSManager"
readonly APP_NAME="SynologyDSManager.app"
readonly SIGNING_XCCONFIG="Signing.xcconfig"
readonly LOCAL_XCCONFIG="Signing.local.xcconfig"
readonly LOCAL_XCCONFIG_TEMPLATE="Signing.local.xcconfig.template"
readonly BUILD_DIR="build"
readonly DERIVED_DATA="${BUILD_DIR}/DerivedData"
readonly DIST_DIR="dist"

# ----- Colours -------------------------------------------------------------
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
    YELLOW=$'\033[33m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

info()  { echo "${BLUE}==>${RESET} $*" >&2; }
ok()    { echo "${GREEN}✓${RESET}  $*" >&2; }
warn()  { echo "${YELLOW}!${RESET}  $*" >&2; }
err()   { echo "${RED}✗${RESET}  $*" >&2; }
fatal() { err "$*"; exit 1; }

pause() { printf "\n${DIM}Press any key to return to the menu…${RESET}"; read -rsn1 _; echo; }

# Human-readable duration for an elapsed-seconds integer. 67 → "1m 7s".
fmt_duration() {
    local secs=$1
    if (( secs < 60 )); then
        echo "${secs}s"
    else
        echo "$((secs / 60))m $((secs % 60))s"
    fi
}

# ----- Sanity checks -------------------------------------------------------

require_macos() {
    [[ "$(uname)" == "Darwin" ]] || fatal "deploy.sh must be run on macOS (detected: $(uname))."
}

require_xcodebuild() {
    command -v xcodebuild >/dev/null 2>&1 \
        || fatal "xcodebuild not found. Install Xcode and run 'xcode-select --install'."
}

# Read DEVELOPMENT_TEAM from Signing.local.xcconfig, return empty if missing.
read_team_id() {
    if [[ ! -f "$LOCAL_XCCONFIG" ]]; then
        echo ""
        return
    fi
    # Grab the RHS of the first `DEVELOPMENT_TEAM =` line, trim whitespace.
    sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([^[:space:]/]+).*/\1/p' \
        "$LOCAL_XCCONFIG" | head -n1
}

require_signing_configured() {
    local team
    team="$(read_team_id)"
    if [[ -z "$team" || "$team" == "YOUR_TEAM_ID_HERE" ]]; then
        warn "Code signing is not configured yet."
        warn "Run the 's' menu option first, or edit $LOCAL_XCCONFIG directly."
        return 1
    fi
    echo "$team"
}

# Read MARKETING_VERSION from the main target's Release config in pbxproj.
read_marketing_version() {
    sed -nE 's/.*MARKETING_VERSION = ([0-9A-Za-z._-]+);.*/\1/p' \
        "${PROJECT}/project.pbxproj" | head -n1
}

# ----- Actions -------------------------------------------------------------

action_pull_main() {
    info "Fetching origin/main…"
    local current_branch
    current_branch="$(git rev-parse --abbrev-ref HEAD)"

    if ! git fetch origin main; then
        err "git fetch origin main failed — check network / auth and try again."
        return 1
    fi

    # When not on main, the working tree is on a different branch so the
    # fetch refspec below can fast-forward the local `main` ref without
    # touching files on disk. No stash dance needed.
    if [[ "$current_branch" != "main" ]]; then
        if git fetch origin main:main; then
            ok "Local 'main' updated from origin/main (you stayed on '${current_branch}')."
            return 0
        else
            err "Could not fast-forward local 'main'. Check out 'main' and resolve manually."
            return 1
        fi
    fi

    # --- From here: on main. ---
    # If there are uncommitted tracked-file changes that overlap with
    # incoming commits, `git pull --ff-only` will refuse. Detect dirty
    # state up-front and offer the user a clean way out.
    local dirty=0
    if ! git diff --quiet || ! git diff --cached --quiet; then
        dirty=1
    fi

    local did_stash=0
    if (( dirty )); then
        echo
        warn "You have uncommitted changes on 'main'."
        echo "  ${BOLD}s${RESET}  Stash them, pull, then reapply"
        echo "  ${BOLD}d${RESET}  Discard them (permanent) and pull"
        echo "  ${BOLD}c${RESET}  Cancel — leave everything as-is"
        printf "Choose [s/d/c]: "
        local reply
        read -rsn1 reply
        echo
        case "$reply" in
            s|S)
                info "Stashing local changes…"
                local stash_msg="deploy.sh auto-stash: pre-pull at $(date +%H:%M:%S)"
                if git stash push -u -m "$stash_msg" >/dev/null; then
                    did_stash=1
                    ok "Stashed (${stash_msg})."
                else
                    err "git stash failed; aborting pull."
                    return 1
                fi
                ;;
            d|D)
                warn "This will permanently discard all uncommitted changes on 'main'."
                printf "Are you sure? [y/N]: "
                local confirm
                read -rsn1 confirm
                echo
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    if git reset --hard HEAD >/dev/null; then
                        ok "Local changes discarded."
                    else
                        err "git reset --hard failed; aborting."
                        return 1
                    fi
                else
                    info "Cancelled — no changes made."
                    return 0
                fi
                ;;
            *)
                info "Cancelled — no changes made."
                return 0
                ;;
        esac
    fi

    # Now safe to pull.
    if ! git pull --ff-only origin main; then
        err "Fast-forward pull failed. Resolve the divergence manually."
        if (( did_stash )); then
            warn "Your changes are safely in 'git stash' (top of the stack)."
            warn "Reapply with:  git stash pop"
        fi
        return 1
    fi
    ok "Local 'main' is now up to date with origin/main."

    # Pop the stash if we made one. `git stash pop` exits non-zero on
    # merge conflicts (but leaves the stash intact for manual recovery).
    if (( did_stash )); then
        info "Reapplying stashed changes…"
        if git stash pop >/dev/null 2>&1; then
            ok "Stash reapplied cleanly."
        else
            warn "Stash pop produced conflicts — resolve manually:"
            warn "  git status          # see conflicted files"
            warn "  (edit files to resolve the <<<<<<< / ======= / >>>>>>> markers)"
            warn "  git add <file>      # mark each as resolved"
            warn "  git stash drop      # remove the now-applied stash entry"
            return 1
        fi
    fi
}

action_open_xcode() {
    info "Opening ${PROJECT} in Xcode…"
    open "${PROJECT}"
    ok "Xcode launched."
}

action_configure_signing() {
    info "Configuring local code signing."

    if [[ -f "$LOCAL_XCCONFIG" ]]; then
        local existing
        existing="$(read_team_id)"
        if [[ -n "$existing" && "$existing" != "YOUR_TEAM_ID_HERE" ]]; then
            ok "Signing already configured (Team ID: ${existing})."
            printf "Overwrite? [y/N] "
            read -rsn1 reply
            echo
            [[ "$reply" =~ ^[Yy]$ ]] || { info "Leaving existing config untouched."; return 0; }
        fi
    fi

    if [[ ! -f "$LOCAL_XCCONFIG_TEMPLATE" ]]; then
        fatal "$LOCAL_XCCONFIG_TEMPLATE is missing — the repo is in an unexpected state."
    fi

    printf "Enter your 10-character Apple Developer Team ID: "
    local team_id
    read -r team_id
    team_id="$(echo "$team_id" | tr -d '[:space:]')"

    if [[ ! "$team_id" =~ ^[A-Z0-9]{10}$ ]]; then
        err "That doesn't look like a valid Team ID (expected 10 uppercase alphanumerics)."
        return 1
    fi

    # Copy template, then substitute. Use a sed expression safe for
    # alphanumerics (no metacharacters expected).
    cp "$LOCAL_XCCONFIG_TEMPLATE" "$LOCAL_XCCONFIG"
    sed -i.bak -E "s/^DEVELOPMENT_TEAM = .*/DEVELOPMENT_TEAM = ${team_id}/" "$LOCAL_XCCONFIG"
    rm -f "${LOCAL_XCCONFIG}.bak"

    ok "Wrote ${LOCAL_XCCONFIG} with Team ID ${team_id}."
    ok "(${LOCAL_XCCONFIG} is gitignored — it will not be committed.)"

    info "Tip: if you want to notarise DMGs, also create a notarytool keychain profile:"
    echo "    xcrun notarytool store-credentials \"SynologyDSManager-Notary\" \\"
    echo "        --apple-id \"you@example.com\" \\"
    echo "        --team-id \"${team_id}\" \\"
    echo "        --password \"<app-specific-password>\""
    echo "    echo SynologyDSManager-Notary > .notary-profile-name"
}

# Build `$SCHEME` in the given configuration ("Debug" or "Release") into
# DerivedData. Echoes the path to the built .app on stdout; diagnostic
# output goes to stderr so callers can safely do `built="$(_build …)"`.
#
# Use Debug for local-install testing (`i`): faster, signed with
# "Apple Development", trusted by Gatekeeper on the signing user's Mac,
# so Safari will load bundled extensions without needing notarisation.
#
# Use Release for distribution (`d` DMG): signed with
# "Developer ID Application", requires notarisation afterwards — Safari
# won't trust the extension until the notarytool staple lands.
_build() {
    local team="$1"
    local config="$2"
    mkdir -p "$BUILD_DIR"

    info "Building ${config} for Team ID ${team} (this takes a minute or two)…"
    local started=$SECONDS

    # Pipe through `xcbeautify` for readable progress when it's installed,
    # otherwise fall back to xcodebuild's raw output.
    # NB: Signing settings come from Signing.xcconfig + Signing.local.xcconfig,
    # which are wired as baseConfigurationReference in the Xcode project.
    if command -v xcbeautify >/dev/null 2>&1; then
        xcodebuild \
            -project "$PROJECT" \
            -scheme "$SCHEME" \
            -configuration "$config" \
            -destination 'generic/platform=macOS' \
            -derivedDataPath "$DERIVED_DATA" \
            DEVELOPMENT_TEAM="$team" \
            build \
            2>&1 | xcbeautify >&2
    else
        xcodebuild \
            -project "$PROJECT" \
            -scheme "$SCHEME" \
            -configuration "$config" \
            -destination 'generic/platform=macOS' \
            -derivedDataPath "$DERIVED_DATA" \
            DEVELOPMENT_TEAM="$team" \
            build >&2
    fi

    local built="${DERIVED_DATA}/Build/Products/${config}/${APP_NAME}"
    if [[ ! -d "$built" ]]; then
        err "Build did not produce ${built}."
        return 1
    fi

    local elapsed=$((SECONDS - started))
    ok "Build finished in $(fmt_duration "$elapsed")."
    echo "$built"
}

action_install() {
    require_xcodebuild
    local team
    team="$(require_signing_configured)" || return 1

    # Debug for local installs: signed with "Apple Development", which
    # Gatekeeper trusts on the signing user's Mac without notarisation.
    # Release (= Developer ID Application) without notarisation would be
    # Gatekeeper-rejected and Safari would refuse to load the bundled
    # Web Extension — see `action_dmg` for the notarised Release path.
    local built
    built="$(_build "$team" "Debug")" || return 1

    local dest="/Applications/${APP_NAME}"
    if [[ -e "$dest" ]]; then
        info "Replacing existing ${dest}."
        rm -rf "$dest"
    fi

    info "Copying built app to ${dest}…"
    if ! cp -R "$built" "$dest"; then
        err "Copy failed: ${built} → ${dest}"
        return 1
    fi

    # Clear the quarantine attribute so Gatekeeper doesn't prompt after install.
    xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true

    # Report the installed size so it's clear the copy actually landed.
    local size
    size="$(du -sh "$dest" 2>/dev/null | awk '{print $1}')"
    ok "Installed ${dest} (${size:-unknown size})."
    printf "Launch now? [y/N] "
    local reply
    read -rsn1 reply
    echo
    [[ "$reply" =~ ^[Yy]$ ]] && open "$dest"
}

action_dmg() {
    require_xcodebuild
    local team
    team="$(require_signing_configured)" || return 1

    # Release + Developer ID for distribution. Notarisation happens below.
    local built
    built="$(_build "$team" "Release")" || return 1

    local version
    version="$(read_marketing_version)"
    [[ -z "$version" ]] && version="dev"

    local staging="${BUILD_DIR}/dmg-staging"
    rm -rf "$staging" && mkdir -p "$staging"
    cp -R "$built" "$staging/"
    ln -s /Applications "$staging/Applications"

    mkdir -p "$DIST_DIR"
    local dmg="${DIST_DIR}/SynologyDSManager-${version}.dmg"
    rm -f "$dmg"

    info "Creating ${dmg}…"
    hdiutil create \
        -volname "SynologyDSManager ${version}" \
        -srcfolder "$staging" \
        -ov -format UDZO \
        "$dmg" >/dev/null

    # Sign the DMG itself so notarisation has something to verify.
    info "Code-signing DMG with Developer ID (Team ${team})…"
    codesign --force --timestamp --sign "Developer ID Application" "$dmg" \
        || warn "DMG signing failed. Check that 'Developer ID Application' is in your keychain."

    ok "DMG created: ${dmg}"

    # Optional notarisation. Looks for a notarytool keychain profile name in
    # `.notary-profile-name` (gitignored). If it's there and readable, offer
    # to notarise + staple.
    if [[ -f .notary-profile-name ]]; then
        local profile
        profile="$(tr -d '[:space:]' < .notary-profile-name)"
        if [[ -n "$profile" ]]; then
            printf "Notarise with profile '%s'? [y/N] " "$profile"
            local reply
            read -rsn1 reply
            echo
            if [[ "$reply" =~ ^[Yy]$ ]]; then
                info "Submitting to Apple notary service (this can take a few minutes)…"
                if xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait; then
                    info "Stapling notarisation ticket to DMG…"
                    xcrun stapler staple "$dmg"
                    ok "Notarised and stapled."
                else
                    warn "Notarisation failed. Run 'xcrun notarytool log …' with the submission ID to inspect."
                fi
            fi
        fi
    else
        info "No .notary-profile-name file found — skipping notarisation."
        info "To enable, run 'xcrun notarytool store-credentials' and write the profile name to .notary-profile-name."
    fi
}

# ----- Menu ----------------------------------------------------------------

print_menu() {
    local team_id
    team_id="$(read_team_id)"
    local status_line
    if [[ -z "$team_id" || "$team_id" == "YOUR_TEAM_ID_HERE" ]]; then
        status_line="${YELLOW}signing not configured${RESET}"
    else
        status_line="${GREEN}signing: Team ${team_id}${RESET}"
    fi

    # No `clear` here — output from the last action stays visible above the
    # menu, so the user can read build logs, error messages, etc. without
    # needing to press a key first.
    echo
    cat <<EOF
${BOLD}SynologyDSManager — deploy.sh${RESET}
${DIM}$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '(no git branch)') · ${status_line}${DIM}${RESET}

  ${BOLD}p${RESET}   Pull main from origin to local
  ${BOLD}o${RESET}   Open in Xcode
  ${BOLD}s${RESET}   Configure signing (Apple Developer Team ID)
  ${BOLD}i${RESET}   Build Debug and install to /Applications (local testing)
  ${BOLD}d${RESET}   Build Release and create a DMG for distribution
  ${BOLD}q${RESET}   Quit

EOF
}

main_loop() {
    require_macos
    while true; do
        print_menu
        printf "Choose: "
        local key
        read -rsn1 key
        echo
        # Actions print their own status. We don't `pause` between actions
        # any more — the menu just reprints (with a blank line above it) so
        # the user flows from command to command without pressing Enter.
        # `|| true` keeps the shell alive if an action fails, and suppresses
        # `set -e` inside the action; each `action_*` therefore needs to
        # check its own critical return codes and surface errors explicitly.
        case "$key" in
            p|P) action_pull_main         || true ;;
            o|O) action_open_xcode        || true ;;
            s|S) action_configure_signing || true ;;
            i|I) action_install           || true ;;
            d|D) action_dmg               || true ;;
            q|Q) echo "Bye."; exit 0 ;;
            "")  ;;  # stray newline
            *)   warn "Unknown option: $key"; sleep 0.5 ;;
        esac
    done
}

main_loop "$@"
