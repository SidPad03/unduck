#!/bin/bash
# Signing helpers shared by package.sh and build-dmg.sh. Source it; it only
# defines functions.

# find_identity <kind>
# Prints "<sha1> <name>" for the first valid identity whose certificate name
# starts with <kind> ("Developer ID Application", "Developer ID Installer"), or
# nothing when there is none. codesign gets the hash rather than the name: a
# renewed certificate leaves two identities with one name, and codesign refuses
# an ambiguous name.
find_identity() {
    local kind="$1" policy="-p codesigning"
    # Installer certificates are not code-signing identities; list them all.
    case "$kind" in *Installer*) policy="" ;; esac
    # shellcheck disable=SC2086
    security find-identity -v $policy 2>/dev/null \
        | grep -E "\"$kind: .*\\([A-Z0-9]+\\)\"\$" \
        | head -1 \
        | sed -E 's/^ *[0-9]+\) ([0-9A-F]{40}) "(.*)"$/\1 \2/' || true
}

# resolve_signing: pick the identities to sign with. Sets SIGN_ID (what codesign
# gets: a hash, a name, or "-" for ad-hoc), SIGN_NAME (for messages) and
# PKG_NAME (the installer identity, empty for an unsigned .pkg). In order:
#   APPLE_SIGNING_IDENTITY / APPLE_INSTALLER_IDENTITY, if set
#   the "Developer ID Application" / "Developer ID Installer" identities in the keychain
#   ad-hoc and an unsigned .pkg, which is what a pull-request build gets
resolve_signing() {
    local found
    if [ -n "${APPLE_SIGNING_IDENTITY:-}" ]; then
        SIGN_ID="$APPLE_SIGNING_IDENTITY"; SIGN_NAME="$APPLE_SIGNING_IDENTITY"
    elif found="$(find_identity "Developer ID Application")" && [ -n "$found" ]; then
        SIGN_ID="${found%% *}"; SIGN_NAME="${found#* }"
    else
        SIGN_ID="-"; SIGN_NAME="ad-hoc"
    fi
    if [ -n "${APPLE_INSTALLER_IDENTITY:-}" ]; then
        PKG_NAME="$APPLE_INSTALLER_IDENTITY"
    elif found="$(find_identity "Developer ID Installer")" && [ -n "$found" ]; then
        PKG_NAME="${found#* }"
    else
        PKG_NAME=""
    fi
}

# notary_ready: are there credentials to notarize with? Either NOTARY_PROFILE
# (made once with `xcrun notarytool store-credentials`) or APPLE_ID,
# APPLE_PASSWORD (an app-specific password) and APPLE_TEAM_ID, which is what CI
# has.
notary_ready() {
    [ -n "${NOTARY_PROFILE:-}" ] ||
        { [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; }
}

# notarize <file>: submit a .dmg or .pkg, wait for Apple's verdict, staple it.
# `notarytool submit --wait` can finish without error on a submission Apple
# rejected, so the verdict is read from its JSON, and a rejection prints Apple's
# log, which names the offending file and the reason.
notarize() {
    local -a auth
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        auth=(--keychain-profile "$NOTARY_PROFILE")
    else
        auth=(--apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID")
    fi
    echo "==> Notarizing $(basename "$1") (usually a few minutes)"
    local out id status
    out="$(xcrun notarytool submit "$1" "${auth[@]}" --wait --output-format json)" || true
    id="$(plutil -extract id raw -o - - <<<"$out" 2>/dev/null || true)"
    status="$(plutil -extract status raw -o - - <<<"$out" 2>/dev/null || true)"
    if [ "$status" != "Accepted" ]; then
        echo "!! notarization of $(basename "$1") did not succeed (${status:-no response})" >&2
        echo "$out" >&2
        [ -n "$id" ] && xcrun notarytool log "$id" "${auth[@]}" >&2
        exit 1
    fi
    xcrun stapler staple "$1"
    echo "    notarized and stapled ($id)"
}
