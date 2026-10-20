# Claude: Music for Airports

A [Claude Code](https://code.claude.com) hook that turns what Claude is doing into a sparse, event-driven rendition of "1/1" from Brian Eno's *Ambient 1: Music for Airports* (1978).

Nothing plays on its own. Every sound is triggered by a Claude Code hook event, so silence means Claude is quiet. Each tool call plays the next one to three notes of the 1/1 piano melody. Over a session the tune unfolds in fragments, paced by whatever Claude is doing.

## What you hear

| Claude event | Sound |
|---|---|
| Tool call (`PreToolUse`) | The next 1–3 notes of the melody (chosen at random), on the slowed piano |
| Tool failure | The next melody note, an octave down |
| Permission request | The current note with its octave above |
| Claude's message (`MessageDisplay`, final piece) | Voices sing the current melody note over the chord root |
| New prompt, subagent start/stop, task created/completed | Voices sing the chord under the current bar |
| Claude finishes (`Stop`) | A home D chord on the voices, with a low piano D |
| Context compaction | A low voice on the current chord's root |

There are two instruments, both synthesised (no samples):

- **Piano**, after 1/1. A soft FM electric piano voiced as if the tape were slowed to half speed, the way Eno slowed Robert Wyatt's piano loop. It has a blurred attack, dark tone and slow tape wobble.
- **Voices**, after the sung loops of 2/1. A wordless "ahh" from three slightly detuned voices shaped by vowel formants, swelling in and out over seven seconds.

Everything runs through a long, dark echo and a hall reverb. The place in the melody is remembered between turns, and the tune loops when it reaches the end.

## How it works

- **One player process.** A single long-running process synthesises all audio with `AVAudioEngine`.
- **The hook.** The hook command (`music-for-airports event`) reads the hook's JSON from stdin and passes it to the player with a distributed notification. If no player is running, it starts one.
- **Exiting.** The player exits a few seconds after everything has rung out.
- **Melody order.** Tool calls that arrive while a phrase is still playing queue behind it, one note each, so the melody stays in order. During a burst of parallel tool calls with more than 3 seconds queued, the extra calls are skipped.
- **Hooks run in the background.** They are registered with `async: true`, so they never slow Claude down.

## Install

Requires macOS, Xcode command-line tools (`clang`) and `jq`.

```sh
./install.sh
```

The script:

1. builds the player into `~/.claude/hooks/music-for-airports/`;
2. adds the hook to 14 events in `~/.claude/settings.json`, leaving your other settings and hooks untouched.

It backs up `settings.json` before changing it, validates the result before writing, and is safe to re-run.

## Try it

```sh
~/.claude/hooks/music-for-airports/music-for-airports send PreToolUse Read
~/.claude/hooks/music-for-airports/music-for-airports send MessageDisplay
~/.claude/hooks/music-for-airports/music-for-airports send Stop
```

To restart the melody from the opening bar, delete `~/.claude/hooks/music-for-airports/state/position`.

## Uninstall

Remove the `music-for-airports event` entries from `~/.claude/settings.json` (or use `/hooks` in Claude Code), then delete `~/.claude/hooks/music-for-airports/`.

## Credits

- **Composition.** "1/1" is by Brian Eno, from *Ambient 1: Music for Airports* (1978). The piano was played by Robert Wyatt.
- **Notes.** The melody and chords were transcribed from M. Hoegeman's MuseScore arrangement of 1/1.
- **Background.** The details on how the record was made come from [Reverb Machine](https://reverbmachine.com/blog/deconstructing-brian-eno-music-for-airports/).

This is a personal, non-commercial project.
