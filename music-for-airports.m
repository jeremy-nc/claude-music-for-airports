// Claude: Music for Airports. Turns Claude Code activity into a sparse, event-driven rendition of
// "1/1" from Brian Eno's "Ambient 1: Music for Airports" (1978).
//
// Nothing plays on its own: every sound is triggered by a Claude Code hook event, and silence means
// Claude is quiet. Every event plays the next 1 to 3 notes (chosen at random) of the 1/1 piano
// melody, in order and at their written pitch, so over a session the real tune unfolds in fragments,
// paced by whatever Claude is doing. No event adds a note that is not the melody's next note.
// The place in the melody is kept between turns.
//
//   Piano, for small, quick events such as tool calls. A soft electric-piano note voiced as if the
//   tape were slowed to half speed, the way Eno slowed Robert Wyatt's piano loop: a blurred attack,
//   dark and bassy, with slow tape wobble.
//
//   Voices, for bigger moments such as messages, prompts and finishing. The same melody notes sung
//   as a wordless "ahh" by three slightly detuned voices, swelling slowly in and out (after the sung
//   loops of 2/1).
//
// The melody is from M. Hoegeman's arrangement of 1/1 (D major). Everything goes through a long,
// dark, smeared echo and a hall reverb.
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

// The 1/1 piano melody as MIDI note numbers, as written, bar by bar.
static const int kMelody[] = {
  79, 81, 78, 76, 74, 86,      // bar 1
  79, 81, 78, 76, 74,          // bars 2-4
  79, 81, 78, 76, 74, 86,      // bar 5
  78, 81, 79, 74,              // bars 6-8
  69, 76, 74, 78, 81, 86, 79,  // bar 9
  76, 81, 78, 74, 81, 79, 79,  // bar 10
  79, 76, 78, 74,              // bar 11
  81, 81, 74, 78, 78,          // bar 12
  78, 74, 69, 74,              // bars 13-14
};
enum { kMelodyLength = sizeof(kMelody) / sizeof(kMelody[0]) };

// The arrangement is written an octave above where it sounds (treble clef with an 8 below).
static const int kSoundingOffset = -12;

static double frequencyOfNote(int midiNote) {
  return 440 * pow(2, (midiNote - 69) / 12.0);
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

// Each event plays a short run of 1 to 3 consecutive melody notes, spaced like a slow phrase.
static const int kMaxRunLength = 3;
static const double kRunSpacingSeconds = 0.55;
static const double kRunSpacingJitterSeconds = 0.25;
// Events that arrive while a run is still playing queue behind it, one note each, so the melody
// stays in order. Beyond this much queued time (a burst of parallel tool calls) they are skipped.
static const double kMaxBacklogSeconds = 3;

enum { kMaxNotesPerResponse = 3 };

typedef struct {
  NoteRequest notes[kMaxNotesPerResponse];
  int count;
  double melodyBusySeconds;  // how long until the melody is free for the next run, if it moved
} Response;

// MessageDisplay fires repeatedly while a message streams in; only its final piece makes a sound.
// PostToolBatch would double the notes its tool calls already played, so it stays silent.
static BOOL isAudible(NSDictionary *payload) {
  NSString *event = payload[@"hook_event_name"];
  if ([event isEqual:@"MessageDisplay"]) return [payload[@"final"] isEqual:@YES];
  if ([event isEqual:@"PostToolBatch"]) return NO;
  return event != nil;
}

// Small, quick events play on the piano; bigger moments on the voices.
static Instrument instrumentForEvent(NSString *event) {
  static NSSet<NSString *> *pianoEvents;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    pianoEvents = [NSSet setWithArray:@[@"PreToolUse", @"PostToolUseFailure", @"PermissionRequest"]];
  });
  return [pianoEvents containsObject:event] ? InstrumentPiano : InstrumentVoices;
}

// Plays the next 1 to 3 melody notes and advances `position` (the index of the next note) past them.
// `backlogSeconds` is how long the melody is still busy with earlier runs; while it is busy, an event
// adds a single note after them, and beyond kMaxBacklogSeconds it adds nothing.
static Response respond(NSDictionary *payload, int *position, double backlogSeconds) {
  Response response = { .count = 0, .melodyBusySeconds = 0 };
  if (backlogSeconds > kMaxBacklogSeconds) return response;

  Instrument instrument = instrumentForEvent(payload[@"hook_event_name"]);
  int runLength = backlogSeconds > 0 ? 1 : 1 + (int)arc4random_uniform(kMaxRunLength);
  double delay = backlogSeconds;
  for (int i = 0; i < runLength && response.count < kMaxNotesPerResponse; i++) {
    double frequency = frequencyOfNote(kMelody[*position] + kSoundingOffset);
    response.notes[response.count++] = (NoteRequest){ instrument, frequency, 1.0, delay };
    *position = (*position + 1) % kMelodyLength;
    delay += kRunSpacingSeconds + kRunSpacingJitterSeconds * (arc4random_uniform(1000) / 1000.0);
  }
  response.melodyBusySeconds = delay;
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
