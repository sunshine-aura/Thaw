#!/usr/bin/env bash
#
# Shared helpers for local Debug builds that must be ad-hoc signed with your
# Apple Development identity (required for macOS 27 menu-bar hiding in /Applications).
#
# Resolution order for the development team:
#   1. THAW_DEVELOPMENT_TEAM environment variable
#   2. scripts/signing.local.sh (copy from signing.local.sh.example; gitignored)
#   3. First "Apple Development" codesigning identity in the login keychain
#
resolve_development_team() {
    local repo_root="${1:?repo root required}"

    if [[ -n "${THAW_DEVELOPMENT_TEAM:-}" ]]; then
        echo "$THAW_DEVELOPMENT_TEAM"
        return 0
    fi

    local local_file="${repo_root}/scripts/signing.local.sh"
    if [[ -f "$local_file" ]]; then
        # shellcheck source=/dev/null
        source "$local_file"
        if [[ -n "${THAW_DEVELOPMENT_TEAM:-}" ]]; then
            echo "$THAW_DEVELOPMENT_TEAM"
            return 0
        fi
    fi

    local team
    team=$(
        security find-identity -v -p codesigning 2>/dev/null |
            sed -nE 's/^[[:space:]]*[0-9]+\) [A-F0-9]{40} "Apple Development: .* \(([A-Z0-9]{10})\)".*/\1/p' |
            head -1
    )
    if [[ -n "$team" ]]; then
        echo "$team"
        return 0
    fi

    return 1
}

# Prints xcodebuild KEY=value signing overrides (one per line).
xcodebuild_signing_settings() {
    local team="${1:?development team required}"
    printf '%s\n' \
        "DEVELOPMENT_TEAM=${team}" \
        "CODE_SIGN_STYLE=Automatic" \
        "CODE_SIGN_IDENTITY=Apple Development"
}

signing_setup_hint() {
    cat <<'EOF'
Could not determine your Apple Development team.

Fix one of:
  • Copy scripts/signing.local.sh.example → scripts/signing.local.sh and set THAW_DEVELOPMENT_TEAM
  • Export THAW_DEVELOPMENT_TEAM for this shell
  • Install an "Apple Development" signing certificate (Xcode → Settings → Accounts)

List identities:
  security find-identity -v -p codesigning | grep "Apple Development"
EOF
}
