#!/bin/zsh
# Builds Claude: Music for Airports, installs it into ~/.claude/hooks/music-for-airports and
# registers it on the Claude Code hook events it plays on. Safe to re-run: events that already
# have the hook are left alone, and settings.json is backed up before any change.
set -euo pipefail

src_dir=${0:A:h}
install_dir="$HOME/.claude/hooks/music-for-airports"
settings="$HOME/.claude/settings.json"
hook_command="~/.claude/hooks/music-for-airports/music-for-airports event"
events=(UserPromptSubmit MessageDisplay PreToolUse PostToolUseFailure PostToolBatch
        SubagentStart SubagentStop TaskCreated TaskCompleted PermissionRequest
        Stop StopFailure PreCompact PostCompact)

for tool in clang jq; do
  command -v $tool >/dev/null || { echo "install.sh needs $tool" >&2; exit 1; }
done

mkdir -p "$install_dir"
clang -fobjc-arc -Wall -Werror -framework Foundation -framework AVFoundation \
  "$src_dir/music-for-airports.m" -o "$install_dir/music-for-airports.new"
# Swap rather than overwrite, so a player that is mid-note keeps its own copy of the binary.
mv "$install_dir/music-for-airports.new" "$install_dir/music-for-airports"
pkill -f 'music-for-airports run' || true
echo "built $install_dir/music-for-airports"

[[ -f "$settings" ]] || echo '{}' > "$settings"
jq -e 'type == "object"' "$settings" >/dev/null || { echo "$settings is not a JSON object; not touching it" >&2; exit 1; }

updated=$(mktemp "${settings}.XXXXXX")
trap 'rm -f "$updated"' EXIT
jq --arg cmd "$hook_command" --args '
  reduce $ARGS.positional[] as $event (.;
    if any(.hooks[$event][]?.hooks[]?; .command == $cmd) then .
    else .hooks[$event] = ((.hooks[$event] // []) + [{"hooks": [{"type": "command", "command": $cmd, "async": true, "timeout": 10}]}])
    end)
' "${events[@]}" < "$settings" > "$updated"

# Only ever add: the result must be valid JSON that still contains every original top-level key.
jq -e --slurpfile original "$settings" '
  type == "object" and ($original[0] | keys) - keys == []
' "$updated" >/dev/null || { echo "generated settings failed validation; $settings left unchanged" >&2; exit 1; }

if jq -e --slurpfile original "$settings" '. == $original[0]' "$updated" >/dev/null; then
  echo "hooks already registered in $settings"
else
  backup="$settings.bak-music-for-airports-$(date +%Y%m%d%H%M%S)"
  cp "$settings" "$backup"
  mv "$updated" "$settings"
  echo "registered hooks in $settings (backup: $backup)"
fi
