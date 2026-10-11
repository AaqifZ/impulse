#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
example_config="$repo_root/examples/actions.json"
personal_config="$repo_root/config/actions.json"

if [[ ! -f "$example_config" ]]; then
    print -u2 "Missing safe example configuration: $example_config"
    exit 1
fi

mkdir -p "$repo_root/config"
if [[ -e "$personal_config" ]]; then
    print "Preserved existing configuration: $personal_config"
else
    umask 077
    cp -n "$example_config" "$personal_config"
    if [[ ! -f "$personal_config" ]]; then
        print -u2 "Configuration appeared concurrently; nothing was overwritten."
        exit 1
    fi
    print "Created personal configuration from the safe example: $personal_config"
fi

"$repo_root/scripts/build.sh"
print "Setup complete. Run: open $repo_root/dist/Impulse.app"
