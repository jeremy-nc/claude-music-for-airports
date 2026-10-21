# Claude: Music for Airports

A [Claude Code](https://code.claude.com) hook that turns what Claude is doing into a sparse, event-driven rendition of "1/1" from Brian Eno's *Ambient 1: Music for Airports* (1978).

Nothing plays on its own. Every sound is triggered by a Claude Code hook event, so silence means Claude is quiet. Every event plays the next one to three notes of the 1/1 piano melody, in order, at their written pitch and with their written rhythm. No event adds a note that isn't the melody's next note. Over a session the tune unfolds in fragments, paced by whatever Claude is doing.

## What you hear

| Claude event | Instrument |
|---|---|
| Tool call, tool failure, permission request | Piano |
| Claude's message (final piece), new prompt, subagent start/stop, task created/completed, compaction, Claude finishes | Voices |

Either way, the event plays the next 1–3 melody notes, chosen at random. Each note lasts its written length from the score, ties included, at 43 BPM, the record's own pace: its eighth notes fall about 0.7 seconds apart. Notes are tuned about 20 cents flat of A = 440 Hz, as measured on the record. The score's rests after each phrase are kept too, so even a busy stretch of work has the record's silences between phrases. `PostToolBatch` stays silent, because its tool calls have already played their notes.

There are two instruments and a background bed, all synthesised (no samples):

- **Piano**, after 1/1. An additive acoustic piano whose partial levels, decay rates and string stretch were measured from the record's own piano notes. Each note has six partials that decay in two stages, a slightly detuned second string that makes it shimmer, a felt hammer, and slow tape wobble. The hammer is played a little harder than on the record.
- **Voices**, after the sung loops of 2/1. The same melody notes sung as a wordless "ahh" by three slightly detuned voices shaped by vowel formants, swelling in and out over seven seconds.
- **Bed.** A quiet D drone with shifting chords above it (Dsus4, G over D, D5), following the chord under the melody's current bar, as heard under the record's melody. It fades in when Claude starts working and fades out when Claude finishes, or after 20 seconds without any event while Claude thinks at length. The next event brings it back.

Everything runs through a long, dark echo, a hall reverb and a gentle high-frequency shelf that keeps the piano's tone close to the record's. The place in the melody is remembered between turns, and the tune loops when it reaches the end.

## How it works

- **One player process.** A single long-running process synthesises all audio with `AVAudioEngine`.
- **The hook.** The hook command (`music-for-airports event`) reads the hook's JSON from stdin and passes it to the player with a distributed notification. If no player is running, it starts one.
- **Exiting.** The player exits a few seconds after everything, including the bed, has rung out.
- **Melody order.** Events that arrive while a phrase is still playing, or during a rest, queue behind it, one note each, so the melody stays in order. Once more than 7 seconds is queued (a burst of tool calls, or one of the score's long rests), the extra events are skipped. Skipping drops events, not melody notes: the tune always resumes at its next note, and the music never trails Claude by more than a few seconds.
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
- **Notes.** The melody was transcribed from M. Hoegeman's MuseScore arrangement of 1/1.
- **Background.** The details on how the record was made come from [Reverb Machine](https://reverbmachine.com/blog/deconstructing-brian-eno-music-for-airports/).

This is a personal, non-commercial project.
