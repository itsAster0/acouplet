#!/bin/zsh
# Build Acouplet locally and optionally install it into /Applications.
#
#   ./build.sh            Build the local package.
#   ./build.sh --install  Build, then install.
#
# With an "Apple Development" signing identity in your keychain (free Apple ID
# signed in under Xcode > Settings > Accounts), this uses the project's own
# installer, which also sets up the battery service, preference panes and LDAC.
# Without one, the app is ad-hoc signed and --install copies only the app;
# LDAC, preference panes and the battery service are unavailable in that mode.
set -euo pipefail

install=false
if (( $# )); then
    if (( $# != 1 )) || [[ "$1" != --install ]]; then
        print -u2 "Usage: ./build.sh [--install]"
        exit 2
    fi
    install=true
fi

repo_root="${0:A:h}"
cd "$repo_root"

if ! developer_dir="$(/usr/bin/xcode-select -p 2>/dev/null)" || [[ "$developer_dir" == /Library/Developer/CommandLineTools ]]; then
    print -u2 "Xcode is required. Install Xcode, then select it under Xcode > Settings > Locations > Command Line Tools."
    exit 1
fi
export DEVELOPER_DIR="$developer_dir"

if /usr/bin/security find-identity -v -p codesigning | grep -q '"Apple Development'; then
    signed=true
    # The project defaults to the upstream author's team; sign with yours instead.
    # The team is the certificate's OU, which the LDAC driver and panes verify.
    if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
        DEVELOPMENT_TEAM="$(/usr/bin/security find-certificate -c "Apple Development" -p |
            /usr/bin/openssl x509 -noout -subject -nameopt multiline 2>/dev/null |
            /usr/bin/sed -n 's/^ *organizationalUnitName *= *//p' | head -1)"
    fi
    if [[ ! "$DEVELOPMENT_TEAM" =~ '^[A-Z0-9]{10}$' ]]; then
        print -u2 "Could not read your team ID from the Apple Development certificate. Set DEVELOPMENT_TEAM=<team ID> and try again."
        exit 1
    fi
    export DEVELOPMENT_TEAM
    print "Signing with your Apple Development identity (team $DEVELOPMENT_TEAM)."
else
    signed=false
    export CODE_SIGN_IDENTITY=-
    print "No Apple Development identity found; building ad-hoc signed."
fi

Packaging/fetch-sparkle.sh
Packaging/package.sh --local

package_dir="$repo_root/.build/local-update/Acouplet"
if [[ "$install" == false ]]; then
    print "\nBuilt: $package_dir/Acouplet.app"
    print "Install with: ./build.sh --install"
    exit 0
fi

if [[ "$signed" == true ]]; then
    exec "$package_dir/Install.command" --require-stopped
fi

installed_app=/Applications/Acouplet.app
if [[ -e "$installed_app" ]] &&
   [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed_app/Contents/Info.plist" 2>/dev/null || true)" != dev.baglayan.Acouplet ]]; then
    print -u2 "$installed_app exists but is not Acouplet. Nothing was replaced."
    exit 1
fi
if /usr/bin/pgrep -f '^/Applications/Acouplet\.app/Contents/MacOS/Acouplet( |$)' >/dev/null; then
    print "Quitting the running Acouplet…"
    /usr/bin/osascript -e 'tell application id "dev.baglayan.Acouplet" to quit'
    for _ in {1..20}; do
        /usr/bin/pgrep -f '^/Applications/Acouplet\.app/Contents/MacOS/Acouplet( |$)' >/dev/null || break
        sleep 0.5
    done
    if /usr/bin/pgrep -f '^/Applications/Acouplet\.app/Contents/MacOS/Acouplet( |$)' >/dev/null; then
        print -u2 "Acouplet is still running. Quit it, then try again."
        exit 1
    fi
fi
staged_app="/Applications/.Acouplet.installing-$$.app"
trap 'rm -rf "$staged_app"' EXIT
/usr/bin/ditto "$package_dir/Acouplet.app" "$staged_app"
# Hardened runtime enforces library validation, which rejects ad-hoc signed
# frameworks such as Sparkle because they carry no team ID. Re-sign the copy
# without it so dyld can load the embedded frameworks.
/usr/bin/codesign --force --deep --sign - --preserve-metadata=entitlements "$staged_app"
/usr/bin/codesign --verify --deep --strict "$staged_app"
rm -rf "$installed_app"
mv "$staged_app" "$installed_app"
print "Installed ad-hoc build to $installed_app (LDAC, preference panes and the battery service are unavailable)."
open "$installed_app"
