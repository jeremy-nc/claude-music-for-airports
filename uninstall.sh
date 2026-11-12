#!/bin/zsh
# Removes Claude: Music for Airports' hooks from ~/.claude/settings.json and stops the player.
# Every other setting and hook is left untouched; settings.json is backed up and validated first.
#
# The program and the place in the melody stay in ~/.claude/hooks/music-for-airports, so ./install.sh
# brings it straight back. Pass --purge to delete that folder as well.
set -euo pipefail

install_dir="$HOME/.claude/hooks/music-for-airports"
settings="$HOME/.claude/settings.json"
hook_command="~/.claude/hooks/music-for-airports/music-for-airports event"
purge=false
[[ "${1:-}" == "--purge" ]] && purge=true

command -v jq >/dev/null || { echo "uninstall.sh needs jq" >&2; exit 1; }

if [[ -f "$settings" ]]; then
  jq -e 'type == "object"' "$settings" >/dev/null || { echo "$settings is not a JSON object; not touching it" >&2; exit 1; }
  updated=$(mktemp "${settings}.XXXXXX")
  trap 'rm -f "$updated"' EXIT
  # Drop this hook; then drop any group or event the removal left empty.
  jq --arg cmd "$hook_command" '
    if .hooks then
      .hooks |= (with_entries(.value |= (map(.hooks |= map(select(.command != $cmd))) | map(select(.hooks | length > 0))))
                 | with_entries(select(.value | length > 0)))
    else . end
  ' < "$settings" > "$updated"

  # Only ever remove this hook: every other hook and top-level setting must survive unchanged.
  jq -e --slurpfile original "$settings" --arg cmd "$hook_command" '
    def others: [.hooks // {} | .[][] .hooks[] | select(.command != $cmd)];
    type == "object"
      and ($original[0] | del(.hooks)) == del(.hooks)
      and ($original[0] | others) == others
      and ([.hooks // {} | .[][] .hooks[] | select(.command == $cmd)] | length) == 0
  ' "$updated" >/dev/null || { echo "generated settings failed validation; $settings left unchanged" >&2; exit 1; }

  if jq -e --slurpfile original "$settings" '. == $original[0]' "$updated" >/dev/null; then
    echo "no Music for Airports hooks in $settings"
  else
    backup="$settings.bak-music-for-airports-uninstall-$(date +%Y%m%d%H%M%S)"
    cp "$settings" "$backup"
    mv "$updated" "$settings"
    echo "removed hooks from $settings (backup: $backup)"
  fi
fi

pkill -f 'music-for-airports run' || true

if $purge; then
  rm -rf "${install_dir:?}"
  echo "deleted $install_dir"
else
  echo "kept $install_dir; run ./install.sh to turn it back on, or ./uninstall.sh --purge to delete it"
fi
