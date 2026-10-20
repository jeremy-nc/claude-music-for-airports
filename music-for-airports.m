// Claude: Music for Airports. Turns Claude Code activity into a sparse, event-driven rendition of
// "1/1" from Brian Eno's "Ambient 1: Music for Airports" (1978).
//
// Nothing plays on its own: every sound is triggered by a Claude Code hook event, and silence means
// Claude is quiet. Each tool call plays the next 1 to 3 notes (chosen at random) of the 1/1 piano
// melody, so over a session the real tune unfolds in fragments, paced by whatever Claude is doing. The place in the melody
// is kept between turns.
//
//   Piano, for small, quick events such as tool calls. A soft electric-piano note voiced as if the
//   tape were slowed to half speed, the way Eno slowed Robert Wyatt's piano loop: a blurred attack,
//   dark and bassy, with slow tape wobble.
//
//   Voices, for bigger moments such as messages, prompts and finishing. A wordless "ahh" sung by
//   three slightly detuned voices, swelling slowly in and out, singing the chord under the current
//   point in the melody (after the sung loops of 2/1).
//
// Melody and chords are from M. Hoegeman's arrangement of 1/1 (D major, turning D mixolydian with a
// C natural near the end). Everything goes through a long, dark, smeared echo and a hall reverb.
//
//   music-for-airports event                 hook entry point: reads the hook payload (JSON) on stdin
//   music-for-airports send <event> [tool]   sends a synthetic event, for trying sounds by hand
//   music-for-airports run [payload]         the player; started on demand, exits once it is silent
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdatomic.h>
#include <sys/file.h>

extern char **environ;

static NSString *const kEventNotification = @"com.jeremyheritage.music-for-airports.event";
static NSString *const kPayloadKey = @"payload";

static const double kSampleRate = 44100;

#pragma mark - The piece

typedef NS_ENUM(int, Chord) { ChordDsus4, ChordGadd9, ChordD5, ChordD7sus4 };

// MIDI note numbers for each chord, from the arrangement's chord symbols.
static const int kChordNotes[][4] = {
  [ChordDsus4] = { 62, 67, 69, 62 },   // D G A
  [ChordGadd9] = { 55, 59, 62, 69 },   // G B D A
  [ChordD5] = { 50, 57, 62, 57 },      // D A D
  [ChordD7sus4] = { 62, 67, 69, 72 },  // D G A C: the C natural that turns 1/1 mixolydian
};

typedef struct {
  int note;  // MIDI note number, as written
  Chord chord;
} MelodyNote;

// The 1/1 piano melody, bar by bar, with the chord underneath each bar.
static const MelodyNote kMelody[] = {
  { 79, ChordDsus4 }, { 81, ChordDsus4 }, { 78, ChordDsus4 }, { 76, ChordDsus4 }, { 74, ChordDsus4 }, { 86, ChordDsus4 },  // bar 1
  { 79, ChordDsus4 }, { 81, ChordDsus4 }, { 78, ChordDsus4 }, { 76, ChordDsus4 }, { 74, ChordGadd9 },                     // bars 2-4
  { 79, ChordDsus4 }, { 81, ChordDsus4 }, { 78, ChordDsus4 }, { 76, ChordDsus4 }, { 74, ChordDsus4 }, { 86, ChordDsus4 },  // bar 5
  { 78, ChordD5 }, { 81, ChordD5 }, { 79, ChordD5 }, { 74, ChordD5 },                                                     // bars 6-8
  { 69, ChordGadd9 }, { 76, ChordGadd9 }, { 74, ChordGadd9 }, { 78, ChordGadd9 }, { 81, ChordGadd9 }, { 86, ChordGadd9 }, { 79, ChordGadd9 },  // bar 9
  { 76, ChordGadd9 }, { 81, ChordGadd9 }, { 78, ChordGadd9 }, { 74, ChordGadd9 }, { 81, ChordGadd9 }, { 79, ChordGadd9 }, { 79, ChordGadd9 },  // bar 10
  { 79, ChordD5 }, { 76, ChordD5 }, { 78, ChordD5 }, { 74, ChordD5 },                                                     // bar 11
  { 81, ChordD7sus4 }, { 81, ChordD7sus4 }, { 74, ChordD7sus4 }, { 78, ChordD7sus4 }, { 78, ChordD7sus4 },                // bar 12
  { 78, ChordDsus4 }, { 74, ChordDsus4 }, { 69, ChordDsus4 }, { 74, ChordDsus4 },                                         // bars 13-14
};
enum { kMelodyLength = sizeof(kMelody) / sizeof(kMelody[0]) };

static const int kHomeNote = 62;  // D4

// The arrangement is written an octave above where it sounds (treble clef with an 8 below).
static const int kSoundingOffset = -12;

// The voices sing in the register of the sung loops on the record.
static const double kVoiceLowestHz = 170;
static const double kVoiceHighestHz = 430;

static double frequencyOfNote(int midiNote) {
  return 440 * pow(2, (midiNote - 69) / 12.0);
}

static double inVoiceRegister(double frequency) {
  while (frequency < kVoiceLowestHz) frequency *= 2;
  while (frequency >= kVoiceHighestHz) frequency /= 2;
  return frequency;
}

#pragma mark - Instruments

typedef NS_ENUM(int, Instrument) { InstrumentPiano, InstrumentVoices };

// Piano (1/1).
static const double kPianoAttackSeconds = 0.035;   // tape slowed to half speed blurs the hammer
static const double kPianoDecaySeconds = 7;
static const double kPianoVolume = 0.16;
static const double kPianoBrightnessSeconds = 1.2; // the FM bell tone mellows over this long
static const double kPianoModulationIndex = 1.4;
static const double kPianoLowPassHz = 1600;        // half speed halves the brightness too
static const double kTapeWobbleHz = 0.35;
static const double kTapeWobbleDepth = 0.0015;

// Voices (2/1).
static const double kSungSeconds = 7;
static const double kVoicesVolume = 0.13;
static const double kVibratoHz = 4.8;
static const double kVibratoDepth = 0.004;
static const double kSingerDetune[] = { 0.997, 1.0, 1.0035 };
enum { kSingers = 3 };

// Formants of a sung "ah" for female voices, as (centre Hz, Q, gain).
static const double kFormants[][3] = { { 800, 6, 1.0 }, { 1150, 8, 0.55 }, { 2900, 12, 0.2 } };
enum { kFormantCount = 3 };

typedef struct {
  double b0, b2, a1, a2;  // constant-peak bandpass; b1 is always 0
} Bandpass;

typedef struct {
  double x1, x2, y1, y2;
} BandpassState;

static Bandpass formantFilters[kFormantCount];

static Bandpass makeBandpass(double centreHz, double q) {
  double w0 = 2 * M_PI * centreHz / kSampleRate;
  double alpha = sin(w0) / (2 * q);
  double a0 = 1 + alpha;
  return (Bandpass){ .b0 = alpha / a0, .b2 = -alpha / a0, .a1 = -2 * cos(w0) / a0, .a2 = (1 - alpha) / a0 };
}

static double filter(const Bandpass *f, BandpassState *s, double x) {
  double y = f->b0 * x + f->b2 * s->x2 - f->a1 * s->y1 - f->a2 * s->y2;
  s->x2 = s->x1; s->x1 = x;
  s->y2 = s->y1; s->y1 = y;
  return y;
}

static double pianoEnvelope(double age) {
  if (age < kPianoAttackSeconds) return age / kPianoAttackSeconds;
  return exp(-(age - kPianoAttackSeconds) * 4.6 / kPianoDecaySeconds);
}

// A slow swell up and back down across the sung length.
static double sungEnvelope(double age) {
  double s = sin(M_PI * age / kSungSeconds);
  return s * s;
}

static double lengthSeconds(Instrument instrument) {
  return instrument == InstrumentPiano ? kPianoAttackSeconds + kPianoDecaySeconds : kSungSeconds;
}

#pragma mark - Responses to events

typedef struct {
  Instrument instrument;
  double frequency;
  double volume;
  double delaySeconds;  // when to start, relative to the event
} NoteRequest;

// A tool call plays a short run of 1 to 3 consecutive melody notes, spaced like a slow phrase.
static const int kMaxRunLength = 3;
static const double kRunSpacingSeconds = 0.55;
static const double kRunSpacingJitterSeconds = 0.25;
// Tool calls that arrive while a run is still playing queue behind it, one note each, so the
// melody stays in order. Beyond this much queued time (a burst of parallel calls) they are skipped.
static const double kMaxBacklogSeconds = 3;

enum { kMaxNotesPerResponse = 3 };

typedef struct {
  NoteRequest notes[kMaxNotesPerResponse];
  int count;
  double melodyBusySeconds;  // how long until the melody is free for the next run, if it moved
} Response;

static void addPianoAt(Response *response, int writtenNote, double volume, double delaySeconds) {
  if (response->count < kMaxNotesPerResponse) {
    response->notes[response->count++] = (NoteRequest){ InstrumentPiano, frequencyOfNote(writtenNote + kSoundingOffset), volume, delaySeconds };
  }
}

static void addPiano(Response *response, int writtenNote, double volume) {
  addPianoAt(response, writtenNote, volume, 0);
}

static void addVoice(Response *response, int midiNote, double volume) {
  if (response->count < kMaxNotesPerResponse) {
    response->notes[response->count++] = (NoteRequest){ InstrumentVoices, inVoiceRegister(frequencyOfNote(midiNote)), volume, 0 };
  }
}

// Sings two notes of the chord under the current point in the melody.
static void addChord(Response *response, Chord chord, double volume) {
  addVoice(response, kChordNotes[chord][0], volume);
  addVoice(response, kChordNotes[chord][2], volume * 0.7);
}

// MessageDisplay fires repeatedly while a message streams in; only its final piece makes a sound.
static BOOL isAudible(NSDictionary *payload) {
  NSString *event = payload[@"hook_event_name"];
  if ([event isEqual:@"MessageDisplay"]) return [payload[@"final"] isEqual:@YES];
  return event != nil;
}

// `position` is the index of the next melody note. Tool calls advance it by the notes they play;
// other events sound around the current point without moving it. `backlogSeconds` is how long the
// melody is still busy with earlier runs.
static Response respond(NSDictionary *payload, int *position, double backlogSeconds) {
  Response response = { .count = 0, .melodyBusySeconds = 0 };
  NSString *event = payload[@"hook_event_name"];
  const MelodyNote *current = &kMelody[(*position + kMelodyLength - 1) % kMelodyLength];
  void (^advance)(void) = ^{ *position = (*position + 1) % kMelodyLength; };

  if ([event isEqualToString:@"PreToolUse"] || [event isEqualToString:@"PostToolUseFailure"]) {
    if (backlogSeconds > kMaxBacklogSeconds) return response;
    BOOL failed = [event isEqualToString:@"PostToolUseFailure"];
    int runLength = (failed || backlogSeconds > 0) ? 1 : 1 + (int)arc4random_uniform(kMaxRunLength);
    double delay = backlogSeconds;
    for (int i = 0; i < runLength; i++) {
      addPianoAt(&response, kMelody[*position].note - (failed ? 12 : 0), failed ? 0.8 : 1.0, delay);
      advance();
      delay += kRunSpacingSeconds + kRunSpacingJitterSeconds * (arc4random_uniform(1000) / 1000.0);
    }
    response.melodyBusySeconds = delay;
  } else if ([event isEqualToString:@"PermissionRequest"]) {
    addPiano(&response, current->note, 0.7);
    addPiano(&response, current->note + 12, 0.45);
  } else if ([event isEqualToString:@"MessageDisplay"]) {
    addVoice(&response, current->note, 0.8);
    addVoice(&response, kChordNotes[current->chord][0], 0.6);
  } else if ([event isEqualToString:@"UserPromptSubmit"] || [event isEqualToString:@"SubagentStart"] ||
             [event isEqualToString:@"SubagentStop"] || [event isEqualToString:@"TaskCreated"] ||
             [event isEqualToString:@"TaskCompleted"]) {
    addChord(&response, current->chord, 0.8);
  } else if ([event isEqualToString:@"Stop"] || [event isEqualToString:@"StopFailure"]) {
    addChord(&response, ChordD5, 0.9);
    addPiano(&response, kHomeNote, 0.7);
  } else if ([event isEqualToString:@"PreCompact"] || [event isEqualToString:@"PostCompact"]) {
    addVoice(&response, kChordNotes[current->chord][0], 0.7);
  }
  return response;
}

#pragma mark - Audio thread

typedef struct {
  bool active;
  Instrument instrument;
  double frequency;
  double volume;
  double age;
  double phases[kSingers];          // piano uses [0] carrier and [1] modulator
  double lowPassed;                 // piano only
  BandpassState formants[kFormantCount];  // voices only
} Voice;

// Notes travel from the main thread to the audio thread through fixed slots, so the audio thread
// never allocates or locks. A slot goes empty -> ready (main) -> empty (audio).
typedef struct {
  _Atomic(bool) ready;
  Instrument instrument;
  double frequency;
  double volume;
  double delaySeconds;
} PendingNote;

enum { kMaxVoices = 48, kPendingSlots = 32 };

static Voice voices[kMaxVoices];
static PendingNote pending[kPendingSlots];
static double vibratoPhase = 0;
static double wobblePhase = 0;
static _Atomic(bool) everythingSilent = true;

static void startPendingNotes(void) {
  for (int s = 0; s < kPendingSlots; s++) {
    PendingNote *slot = &pending[s];
    if (!atomic_load_explicit(&slot->ready, memory_order_acquire)) continue;
    for (int v = 0; v < kMaxVoices; v++) {
      if (voices[v].active) continue;
      // A negative age is time still to wait before the note sounds.
      voices[v] = (Voice){ .active = true, .instrument = slot->instrument, .frequency = slot->frequency, .volume = slot->volume,
                           .age = -slot->delaySeconds };
      break;
    }
    atomic_store_explicit(&slot->ready, false, memory_order_release);
  }
}

static void step(double *phase, double frequency) {
  *phase += frequency / kSampleRate;
  *phase -= floor(*phase);
}

// A Rhodes-like FM tone: a sine modulated at the same frequency, bright at first, then mellowing.
static double renderPiano(Voice *voice, double wobble) {
  double smoothing = 1 - exp(-2 * M_PI * kPianoLowPassHz / kSampleRate);
  double index = kPianoModulationIndex * exp(-voice->age / kPianoBrightnessSeconds);
  step(&voice->phases[0], voice->frequency * wobble);
  step(&voice->phases[1], voice->frequency * wobble);
  double tone = sin(2 * M_PI * voice->phases[0] + index * sin(2 * M_PI * voice->phases[1]));
  voice->lowPassed += smoothing * (tone - voice->lowPassed);
  return kPianoVolume * pianoEnvelope(voice->age) * voice->lowPassed;
}

// Sawtooth singers, slightly detuned, shaped into an "ah" by the formant filters.
static double renderVoices(Voice *voice, double vibrato) {
  double source = 0;
  for (int s = 0; s < kSingers; s++) {
    step(&voice->phases[s], voice->frequency * kSingerDetune[s] * vibrato);
    source += (2 * voice->phases[s] - 1) / kSingers;
  }
  double vowel = 0;
  for (int f = 0; f < kFormantCount; f++) {
    vowel += kFormants[f][2] * filter(&formantFilters[f], &voice->formants[f], source);
  }
  return kVoicesVolume * sungEnvelope(voice->age) * vowel;
}

static OSStatus render(BOOL *isSilence, const AudioTimeStamp *timestamp, AVAudioFrameCount frameCount, AudioBufferList *output) {
  (void)isSilence; (void)timestamp;
  startPendingNotes();
  float *out = output->mBuffers[0].mData;
  bool anyActive = false;

  for (AVAudioFrameCount i = 0; i < frameCount; i++) {
    double wobble = 1 + kTapeWobbleDepth * sin(2 * M_PI * wobblePhase);
    double vibrato = 1 + kVibratoDepth * sin(2 * M_PI * vibratoPhase);
    double sample = 0;
    for (int v = 0; v < kMaxVoices; v++) {
      Voice *voice = &voices[v];
      if (!voice->active) continue;
      if (voice->age < 0) {
        voice->age += 1 / kSampleRate;
        anyActive = true;
        continue;
      }
      double tone = voice->instrument == InstrumentPiano ? renderPiano(voice, wobble) : renderVoices(voice, vibrato);
      sample += voice->volume * tone;
      voice->age += 1 / kSampleRate;
      if (voice->age >= lengthSeconds(voice->instrument)) voice->active = false;
      else anyActive = true;
    }
    step(&wobblePhase, kTapeWobbleHz);
    step(&vibratoPhase, kVibratoHz);
    out[i] = (float)tanh(sample);
  }
  atomic_store(&everythingSilent, !anyActive);
  return noErr;
}

static void queueNote(Instrument instrument, double frequency, double volume, double delaySeconds) {
  for (int s = 0; s < kPendingSlots; s++) {
    PendingNote *slot = &pending[s];
    if (atomic_load_explicit(&slot->ready, memory_order_acquire)) continue;
    slot->instrument = instrument;
    slot->frequency = frequency;
    slot->volume = volume;
    slot->delaySeconds = delaySeconds;
    atomic_store_explicit(&slot->ready, true, memory_order_release);
    return;
  }
}

#pragma mark - Player process

static const NSTimeInterval kEchoSeconds = 0.9;
static const float kEchoFeedbackPercent = 50;
static const float kEchoMixPercent = 30;
static const float kEchoLowPassHz = 1800;
static const float kReverbMixPercent = 55;
static const NSTimeInterval kRingOutSeconds = 8;  // echo and reverb tail after the last note ends

static NSString *stateDir(void) {
  return [NSHomeDirectory() stringByAppendingPathComponent:@".claude/hooks/music-for-airports/state"];
}

// Holding an exclusive flock on this file is what makes a process "the" player.
static int tryAcquirePlayerLock(void) {
  [[NSFileManager defaultManager] createDirectoryAtPath:stateDir() withIntermediateDirectories:YES attributes:nil error:nil];
  NSString *lockPath = [stateDir() stringByAppendingPathComponent:@"player.lock"];
  int fd = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
  if (fd < 0) return -1;
  if (flock(fd, LOCK_EX | LOCK_NB) != 0) { close(fd); return -1; }
  return fd;
}

static NSDictionary *parsePayload(NSData *json) {
  id payload = json.length ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
  return [payload isKindOfClass:[NSDictionary class]] ? payload : nil;
}

static void sendToPlayer(NSString *payloadJson) {
  [[NSDistributedNotificationCenter defaultCenter] postNotificationName:kEventNotification object:nil
                                                               userInfo:@{ kPayloadKey: payloadJson } deliverImmediately:YES];
}

static int runPlayer(NSString *initialPayloadJson) {
  int lockFd = tryAcquirePlayerLock();
  if (lockFd < 0) {
    // Another player started first; hand it this event instead.
    if (initialPayloadJson) sendToPlayer(initialPayloadJson);
    return 0;
  }
  for (int f = 0; f < kFormantCount; f++) formantFilters[f] = makeBandpass(kFormants[f][0], kFormants[f][1]);

  // The place in the melody is kept between players, so the piece carries on across turns.
  NSString *positionPath = [stateDir() stringByAppendingPathComponent:@"position"];
  NSString *savedPosition = [NSString stringWithContentsOfFile:positionPath encoding:NSUTF8StringEncoding error:nil];
  __block int position = savedPosition ? abs(savedPosition.intValue) % kMelodyLength : 0;
  __block NSDate *lastEventAt = [NSDate date];
  __block NSDate *melodyFreeAt = [NSDate distantPast];
  void (^receive)(NSString *) = ^(NSString *json) {
    NSDictionary *payload = parsePayload([json dataUsingEncoding:NSUTF8StringEncoding]);
    if (!payload || !isAudible(payload)) return;
    lastEventAt = [NSDate date];
    Response response = respond(payload, &position, MAX(0, melodyFreeAt.timeIntervalSinceNow));
    if (response.melodyBusySeconds > 0) melodyFreeAt = [NSDate dateWithTimeIntervalSinceNow:response.melodyBusySeconds];
    for (int i = 0; i < response.count; i++) {
      const NoteRequest *note = &response.notes[i];
      queueNote(note->instrument, note->frequency, note->volume, note->delaySeconds);
    }
    [[NSString stringWithFormat:@"%d", position] writeToFile:positionPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
  };
  [[NSDistributedNotificationCenter defaultCenter] addObserverForName:kEventNotification object:nil queue:NSOperationQueue.mainQueue
                                                           usingBlock:^(NSNotification *notification) {
    id json = notification.userInfo[kPayloadKey];
    if ([json isKindOfClass:[NSString class]]) receive(json);
  }];
  if (initialPayloadJson) receive(initialPayloadJson);

  AVAudioEngine *engine = [AVAudioEngine new];
  AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kSampleRate channels:1];
  AVAudioSourceNode *source = [[AVAudioSourceNode alloc] initWithFormat:format renderBlock:^OSStatus(BOOL *isSilence, const AudioTimeStamp *timestamp, AVAudioFrameCount frameCount, AudioBufferList *output) {
    return render(isSilence, timestamp, frameCount, output);
  }];
  AVAudioUnitDelay *echo = [AVAudioUnitDelay new];
  echo.delayTime = kEchoSeconds;
  echo.feedback = kEchoFeedbackPercent;
  echo.wetDryMix = kEchoMixPercent;
  echo.lowPassCutoff = kEchoLowPassHz;
  AVAudioUnitReverb *reverb = [AVAudioUnitReverb new];
  [reverb loadFactoryPreset:AVAudioUnitReverbPresetLargeHall2];
  reverb.wetDryMix = kReverbMixPercent;

  for (AVAudioNode *node in @[source, echo, reverb]) [engine attachNode:node];
  [engine connect:source to:echo format:format];
  [engine connect:echo to:reverb format:format];
  [engine connect:reverb to:engine.mainMixerNode format:nil];
  if (![engine startAndReturnError:nil]) return 1;

  // Stay alive while anything is sounding, or briefly after the last event in case more follow.
  do {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
  } while (!atomic_load(&everythingSilent) || -lastEventAt.timeIntervalSinceNow < kRingOutSeconds);
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:kRingOutSeconds]];
  [engine stop];
  close(lockFd);
  return 0;
}

static void launchPlayer(NSString *payloadJson) {
  posix_spawnattr_t attr;
  posix_spawnattr_init(&attr);
  posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
  posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
  posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
  const char *selfPath = NSBundle.mainBundle.executablePath.fileSystemRepresentation;
  char *const args[] = { (char *)selfPath, "run", (char *)payloadJson.UTF8String, NULL };
  pid_t pid;
  posix_spawn(&pid, selfPath, &actions, &attr, args, environ);
  posix_spawn_file_actions_destroy(&actions);
  posix_spawnattr_destroy(&attr);
}

// Sends one event to the running player, starting the player first if none is running.
static int deliver(NSDictionary *payload) {
  if (!payload || !isAudible(payload)) return 0;
  NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  NSString *payloadJson = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];

  int probeFd = tryAcquirePlayerLock();
  if (probeFd >= 0) {
    close(probeFd);
    launchPlayer(payloadJson);
  } else {
    sendToPlayer(payloadJson);
  }
  return 0;
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    NSString *command = argc > 1 ? @(argv[1]) : @"";
    if ([command isEqualToString:@"event"]) {
      return deliver(parsePayload([[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile]));
    }
    if ([command isEqualToString:@"send"] && argc > 2) {
      NSMutableDictionary *payload = [@{ @"hook_event_name": @(argv[2]), @"final": @YES } mutableCopy];
      if (argc > 3) payload[@"tool_name"] = @(argv[3]);
      return deliver(payload);
    }
    if ([command isEqualToString:@"run"]) return runPlayer(argc > 2 ? @(argv[2]) : nil);
    fprintf(stderr, "usage: music-for-airports event | send <hook event> [tool name] | run [payload json]\n");
    return 2;
  }
}
