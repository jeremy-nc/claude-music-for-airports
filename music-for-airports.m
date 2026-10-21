// Claude: Music for Airports. Turns Claude Code activity into a sparse, event-driven rendition of
// "1/1" from Brian Eno's "Ambient 1: Music for Airports" (1978).
//
// Nothing plays on its own: every sound is triggered by a Claude Code hook event, and silence means
// Claude is quiet. Every event plays the next 1 to 3 notes (chosen at random) of the 1/1 piano
// melody, in order and at their written pitch, so over a session the real tune unfolds in fragments,
// paced by whatever Claude is doing. No event adds a note that is not the melody's next note.
// The place in the melody is kept between turns.
//
//   Piano, for small, quick events such as tool calls. An additive acoustic piano measured from the
//   record's own piano notes (as heard, slowed to half speed), with slow tape wobble.
//
//   Voices, for bigger moments such as messages, prompts and finishing. The same melody notes sung
//   as a wordless "ahh" by three slightly detuned voices, swelling slowly in and out (after the sung
//   loops of 2/1).
//
//   Bed, under both while Claude is working: a quiet D drone following the melody's chords.
//
// The melody is from M. Hoegeman's arrangement of 1/1 (D major). Everything goes through a long,
// dark, smeared echo, a hall reverb and a high shelf that keeps the piano's tone near the record's.
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

// Measured from the record: its eighth notes are about 0.70 s apart, so roughly 43 BPM (the
// arrangement is marked 65; Eno's half-speed tape lands the record between the two). One eighth
// note lasts 60 / kTempoBpm / 2 seconds.
static const double kTempoBpm = 43;

// The bed's chords: a D drone with shifting notes above it, as measured under the record's melody
// and written in the arrangement's bass part.
typedef NS_ENUM(int, BedChord) {
  BedChordSus4,     // D2 G2 A2 D3 (Dsus4)
  BedChordGOverD,   // D2 G2 D3 G3 (the arrangement's G(add9) over the D drone)
  BedChordFifth,    // D2 A2 D3 A3 (the arrangement's D5)
};

typedef struct {
  int note;          // MIDI note number, as written
  int eighths;       // written length in eighth notes, including ties
  int restEighths;   // written rest after the note before the next one, in eighth notes
  BedChord chord;    // the chord under this note's bar
} MelodyNote;

// The 1/1 piano melody, bar by bar.
static const MelodyNote kMelody[] = {
  // bar 1
  { 79, 1, 0, BedChordSus4 }, { 81, 1, 0, BedChordSus4 }, { 78, 1, 0, BedChordSus4 }, { 76, 1, 0, BedChordSus4 },
  { 74, 1, 0, BedChordSus4 }, { 86, 3, 0, BedChordSus4 },
  // bars 2-4, the held D over G(add9), then a rest to bar 5
  { 79, 1, 0, BedChordSus4 }, { 81, 1, 0, BedChordSus4 }, { 78, 1, 0, BedChordSus4 }, { 76, 1, 0, BedChordSus4 },
  { 74, 6, 14, BedChordGOverD },
  // bar 5
  { 79, 1, 0, BedChordSus4 }, { 81, 1, 0, BedChordSus4 }, { 78, 1, 0, BedChordSus4 }, { 76, 1, 0, BedChordSus4 },
  { 74, 1, 0, BedChordSus4 }, { 86, 4, 0, BedChordSus4 },
  // bars 6-8, then a rest to bar 9
  { 78, 1, 0, BedChordFifth }, { 81, 1, 0, BedChordFifth }, { 79, 2, 0, BedChordFifth }, { 74, 5, 12, BedChordFifth },
  // bar 9
  { 69, 2, 0, BedChordGOverD }, { 76, 1, 0, BedChordGOverD }, { 74, 1, 0, BedChordGOverD }, { 78, 1, 0, BedChordGOverD },
  { 81, 1, 0, BedChordGOverD }, { 86, 1, 0, BedChordGOverD }, { 79, 1, 0, BedChordGOverD },
  // bar 10
  { 76, 1, 0, BedChordGOverD }, { 81, 1, 0, BedChordGOverD }, { 78, 2, 0, BedChordGOverD }, { 74, 1, 0, BedChordGOverD },
  { 81, 1, 0, BedChordGOverD }, { 79, 1, 0, BedChordGOverD }, { 79, 1, 0, BedChordGOverD },
  // bar 11
  { 79, 1, 0, BedChordFifth }, { 76, 1, 0, BedChordFifth }, { 78, 2, 0, BedChordFifth }, { 74, 4, 1, BedChordFifth },
  // bar 12
  { 81, 1, 0, BedChordSus4 }, { 81, 2, 0, BedChordSus4 }, { 74, 1, 0, BedChordSus4 }, { 78, 1, 0, BedChordSus4 },
  { 78, 2, 0, BedChordSus4 },
  // bars 13-14, then the rest opening bar 1
  { 78, 2, 0, BedChordFifth }, { 74, 1, 0, BedChordFifth }, { 69, 1, 0, BedChordFifth }, { 74, 2, 0, BedChordFifth },
  { 74, 10, 2, BedChordFifth },
};
enum { kMelodyLength = sizeof(kMelody) / sizeof(kMelody[0]) };

// The arrangement is written an octave above where it sounds (treble clef with an 8 below).
static const int kSoundingOffset = -12;

// Measured from the record: its notes sit about 20 cents flat of A = 440 Hz, as tape playback
// leaves them.
static const double kTuningCents = -20;

static double frequencyOfNote(int midiNote) {
  return 440 * pow(2, (midiNote - 69 + kTuningCents / 100) / 12.0);
}

#pragma mark - Instruments

typedef NS_ENUM(int, Instrument) { InstrumentPiano, InstrumentVoices };

// Piano (1/1): additive synthesis of an acoustic piano, every parameter measured from the 55 clean
// acoustic-piano notes in the record (as heard, i.e. already slowed to half speed).
//
// Each note is six partials. Each partial has its own level, is sharpened by the string's
// inharmonicity, decays in two stages (a fast strike, then its own slower ring, higher partials dying
// faster) and is doubled by a slightly detuned second string, whose beating gives the shimmer. A short,
// noise burst adds the hammer.
//
// The hammer is played harder than on the record: a faster attack, a louder and brighter noise burst,
// and upper partials that flare briefly at the strike before settling into the measured levels.
enum { kPianoPartials = 6, kPianoOscillators = 2 * kPianoPartials };
static const double kPianoPartialLevelDb[kPianoPartials] = { 0, -17.8, -25.1, -23.4, -31.2, -43.5 };
static const double kPianoStrikeDbPerSecond[kPianoPartials] = { -40.3, -11.8, -26.8, -13.6, -32.0, -27.7 };
static const double kPianoRingDbPerSecond[kPianoPartials] = { -8.6, -8.9, -21.4, -36.0, -26.5, -23.5 };
static const double kPianoStrikeSeconds = 0.5;     // where the fast strike gives way to the ring
static const double kPianoInharmonicity = 0.001;   // partial k sits at k * f0 * sqrt(1 + B k^2)
// The second string: 5 cents sharp beats at about 0.9 Hz on the fundamental, as measured, and faster
// on higher partials. Quieter than the first, as part of the record's measured beating is its echo.
static const double kPianoSecondStringCents = 5;
static const double kPianoSecondStringLevel = 0.35;
static const double kPianoHammerLevel = 0.15;
static const double kPianoHammerSeconds = 0.02;    // the noise burst's decay time constant
static const double kPianoHammerLowPassHz = 3000;  // a felt "tock": brighter than a thud, softer than a click
// The strike's flare: the top partial starts this much louder, lower partials proportionally less, and
// the extra fades with this time constant.
static const double kPianoStrikeFlareDb = 12;
static const double kPianoStrikeFlareSeconds = 0.06;
// An S-curve (raised cosine) attack, smooth at both ends; 30 ms gives a 10-90% rise of about 18 ms,
// twice as sharp as the record's measured 39 ms.
static const double kPianoAttackSeconds = 0.03;
static const double kPianoSeconds = 6.5;            // until the fundamental has rung down by ~70 dB
static const double kPianoVolume = 0.13;
static const double kTapeWobbleHz = 0.35;
static const double kTapeWobbleDepth = 0.0015;

// Voices (2/1).
static const double kSungSeconds = 7;
static const double kVoicesVolume = 0.13;
static const double kVibratoHz = 4.8;
static const double kVibratoDepth = 0.004;
static const double kSingerDetune[] = { 0.997, 1.0, 1.0035 };
enum { kSingers = 3 };

// Bed: the low, sustained layer under the record's melody. It plays only while Claude is working:
// fading in with the prompt, following the melody's chords, and fading out after Claude finishes.
static const double kBedVolume = 0.035;           // per note; quiet under the piano
static const double kBedFadeInSeconds = 4;
static const double kBedFadeOutSeconds = 8;
static const double kBedCrossfadeSeconds = 3;     // between chords
// Fades out when no event has arrived for this long: while Claude thinks at length, or if a turn ends
// without a Stop event. The next event fades it back in.
static const NSTimeInterval kBedIdleSeconds = 20;
// Each note swells slowly on one of Eno's unrelated loop lengths, so the bed shimmers.
static const double kBedSwellSeconds[] = { 23.5, 25.875, 29.9375, 19.6 };
enum { kBedNotes = 4 };
// Sounding MIDI notes of each chord, as measured on the record (D2 = 38).
static const int kBedVoicings[][kBedNotes] = {
  [BedChordSus4] = { 38, 43, 45, 50 },
  [BedChordGOverD] = { 38, 43, 50, 55 },
  [BedChordFifth] = { 38, 45, 50, 57 },
};

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

static double pianoAttack(double age) {
  return age < kPianoAttackSeconds ? 0.5 - 0.5 * cos(M_PI * age / kPianoAttackSeconds) : 1;
}

// Per-sample decay multipliers for each partial's strike and ring, and each partial's extra gain at the
// instant of the strike, filled once by preparePiano().
static double pianoStrikeFactor[kPianoPartials], pianoRingFactor[kPianoPartials];
static double pianoFlareGain[kPianoPartials];

static void preparePiano(void) {
  for (int k = 0; k < kPianoPartials; k++) {
    pianoStrikeFactor[k] = pow(10, kPianoStrikeDbPerSecond[k] / 20 / kSampleRate);
    pianoRingFactor[k] = pow(10, kPianoRingDbPerSecond[k] / 20 / kSampleRate);
    pianoFlareGain[k] = pow(10, kPianoStrikeFlareDb * k / (kPianoPartials - 1) / 20) - 1;
  }
}

// A slow swell up and back down across the sung length.
static double sungEnvelope(double age) {
  double s = sin(M_PI * age / kSungSeconds);
  return s * s;
}

static double lengthSeconds(Instrument instrument) {
  return instrument == InstrumentPiano ? kPianoSeconds : kSungSeconds;
}

#pragma mark - Responses to events

typedef struct {
  Instrument instrument;
  double frequency;
  double volume;
  double delaySeconds;  // when to start, relative to the event
} NoteRequest;

// Each event plays a short run of 1 to 3 consecutive melody notes, each lasting its written length
// and followed by its written rest, so phrases are separated by the score's silences.
static const int kMaxRunLength = 3;
// Events that arrive while the melody is still sounding or resting queue behind it, one note each,
// so the melody stays in order. Beyond this much queued time (a burst of tool calls, or a long rest)
// they are skipped: the melody waits for the next event rather than trailing Claude.
static const double kMaxBacklogSeconds = 7;

static double eighthsToSeconds(int eighths) {
  return eighths * 60.0 / kTempoBpm / 2;
}

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
    const MelodyNote *note = &kMelody[*position];
    response.notes[response.count++] = (NoteRequest){ instrument, frequencyOfNote(note->note + kSoundingOffset), 1.0, delay };
    *position = (*position + 1) % kMelodyLength;
    delay += eighthsToSeconds(note->eighths + note->restEighths);
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
  double phases[kSingers];                        // voices only
  BandpassState formants[kFormantCount];          // voices only
  double partialPhases[kPianoOscillators];        // piano only: each partial, then its second string
  double partialFrequencies[kPianoOscillators];   // piano only, set when the note starts
  double partialAmplitudes[kPianoPartials];       // piano only, decaying sample by sample
  double hammerLowPassed[2];                      // piano only: two-pole low-pass of the hammer noise
  uint32_t noiseState;                            // piano only
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

static void startPianoVoice(Voice *voice) {
  double secondString = pow(2, kPianoSecondStringCents / 1200);
  for (int k = 0; k < kPianoPartials; k++) {
    int harmonic = k + 1;
    double frequency = harmonic * voice->frequency * sqrt(1 + kPianoInharmonicity * harmonic * harmonic);
    voice->partialFrequencies[k] = frequency;
    voice->partialFrequencies[kPianoPartials + k] = frequency * secondString;
    voice->partialAmplitudes[k] = pow(10, kPianoPartialLevelDb[k] / 20);
  }
}

static void startPendingNotes(void) {
  for (int s = 0; s < kPendingSlots; s++) {
    PendingNote *slot = &pending[s];
    if (!atomic_load_explicit(&slot->ready, memory_order_acquire)) continue;
    for (int v = 0; v < kMaxVoices; v++) {
      if (voices[v].active) continue;
      // A negative age is time still to wait before the note sounds.
      voices[v] = (Voice){ .active = true, .instrument = slot->instrument, .frequency = slot->frequency, .volume = slot->volume,
                           .age = -slot->delaySeconds, .noiseState = 0x9E3779B9u ^ (uint32_t)v };
      if (slot->instrument == InstrumentPiano) startPianoVoice(&voices[v]);
      break;
    }
    atomic_store_explicit(&slot->ready, false, memory_order_release);
  }
}

static void step(double *phase, double frequency) {
  *phase += frequency / kSampleRate;
  *phase -= floor(*phase);
}

// A cheap per-voice white-noise source for the hammer (xorshift), in [-1, 1].
static double hammerNoise(Voice *voice) {
  uint32_t n = voice->noiseState;
  n ^= n << 13; n ^= n >> 17; n ^= n << 5;
  voice->noiseState = n;
  return n / 2147483648.0 - 1;
}

// One sample of the additive piano.
static double renderPiano(Voice *voice, double wobble) {
  double sample = 0;
  bool striking = voice->age < kPianoStrikeSeconds;
  double flare = exp(-voice->age / kPianoStrikeFlareSeconds);
  for (int k = 0; k < kPianoPartials; k++) {
    step(&voice->partialPhases[k], voice->partialFrequencies[k] * wobble);
    step(&voice->partialPhases[kPianoPartials + k], voice->partialFrequencies[kPianoPartials + k] * wobble);
    double strings = sin(2 * M_PI * voice->partialPhases[k])
                   + kPianoSecondStringLevel * sin(2 * M_PI * voice->partialPhases[kPianoPartials + k]);
    double flaredAmplitude = voice->partialAmplitudes[k] * (1 + pianoFlareGain[k] * flare);
    sample += flaredAmplitude * strings / (1 + kPianoSecondStringLevel);
    voice->partialAmplitudes[k] *= striking ? pianoStrikeFactor[k] : pianoRingFactor[k];
  }
  if (voice->age < 10 * kPianoHammerSeconds) {
    double smoothing = 1 - exp(-2 * M_PI * kPianoHammerLowPassHz / kSampleRate);
    voice->hammerLowPassed[0] += smoothing * (hammerNoise(voice) - voice->hammerLowPassed[0]);
    voice->hammerLowPassed[1] += smoothing * (voice->hammerLowPassed[0] - voice->hammerLowPassed[1]);
    sample += kPianoHammerLevel * exp(-voice->age / kPianoHammerSeconds) * voice->hammerLowPassed[1];
  }
  return kPianoVolume * pianoAttack(voice->age) * sample;
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

// Bed state. The main thread only sets what it wants; the audio thread owns everything else.
static _Atomic(bool) bedWanted = false;
static _Atomic(int) bedWantedChord = BedChordSus4;
static double bedLevel = 0;
static int bedChord = BedChordSus4, bedPreviousChord = BedChordSus4;
static double bedCrossfade = 1;
static double bedPhases[2][kBedNotes];   // [0] current chord, [1] previous chord
static double bedTime = 0;
static double bedFrequencies[3][kBedNotes];   // filled once by prepareBed()

static void prepareBed(void) {
  for (int chord = 0; chord < 3; chord++) {
    for (int n = 0; n < kBedNotes; n++) bedFrequencies[chord][n] = frequencyOfNote(kBedVoicings[chord][n]);
  }
}

static double renderBedChord(int chord, double *phases) {
  double sample = 0;
  for (int n = 0; n < kBedNotes; n++) {
    double swell = 0.6 + 0.4 * sin(2 * M_PI * bedTime / kBedSwellSeconds[n]);
    step(&phases[n], bedFrequencies[chord][n]);
    sample += swell * sin(2 * M_PI * phases[n]);
  }
  return sample;
}

// One sample of the bed, or 0 once it has faded out.
static double renderBed(void) {
  bool wanted = atomic_load(&bedWanted);
  bedLevel += (wanted ? 1 / kBedFadeInSeconds : -1 / kBedFadeOutSeconds) / kSampleRate;
  bedLevel = MIN(1, MAX(0, bedLevel));
  if (bedLevel == 0) return 0;

  int wantedChord = atomic_load(&bedWantedChord);
  if (wantedChord != bedChord) {
    bedPreviousChord = bedChord;
    memcpy(bedPhases[1], bedPhases[0], sizeof bedPhases[0]);
    bedChord = wantedChord;
    bedCrossfade = 0;
  }
  bedCrossfade = MIN(1, bedCrossfade + 1 / (kBedCrossfadeSeconds * kSampleRate));
  bedTime += 1 / kSampleRate;

  double sample = bedCrossfade * renderBedChord(bedChord, bedPhases[0]);
  if (bedCrossfade < 1) sample += (1 - bedCrossfade) * renderBedChord(bedPreviousChord, bedPhases[1]);
  return kBedVolume * bedLevel * sample;
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
    sample += renderBed();
    step(&wobblePhase, kTapeWobbleHz);
    step(&vibratoPhase, kVibratoHz);
    out[i] = (float)tanh(sample);
  }
  atomic_store(&everythingSilent, !anyActive && bedLevel == 0);
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
// The hall brightens the piano's upper partials by 4-9 dB against its fundamental; this shelf after it
// brings partials 2, 4 and 5 back to within about 2 dB of the record's, and darkens the tail to match.
static const float kToneShelfHz = 500;
static const float kToneShelfDb = -5;
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
  prepareBed();
  preparePiano();

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

    // The bed plays while Claude is working: any event but the end of a turn keeps it going.
    NSString *event = payload[@"hook_event_name"];
    BOOL turnEnded = [event isEqualToString:@"Stop"] || [event isEqualToString:@"StopFailure"];
    atomic_store(&bedWanted, !turnEnded);
    atomic_store(&bedWantedChord, kMelody[(position + kMelodyLength - 1) % kMelodyLength].chord);
  };
  id observer = [[NSDistributedNotificationCenter defaultCenter] addObserverForName:kEventNotification object:nil queue:NSOperationQueue.mainQueue
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
  AVAudioUnitEQ *tone = [[AVAudioUnitEQ alloc] initWithNumberOfBands:1];
  AVAudioUnitEQFilterParameters *shelf = tone.bands[0];
  shelf.filterType = AVAudioUnitEQFilterTypeHighShelf;
  shelf.frequency = kToneShelfHz;
  shelf.gain = kToneShelfDb;
  shelf.bypass = NO;

  for (AVAudioNode *node in @[source, echo, reverb, tone]) [engine attachNode:node];
  [engine connect:source to:echo format:format];
  [engine connect:echo to:reverb format:format];
  [engine connect:reverb to:tone format:nil];
  [engine connect:tone to:engine.mainMixerNode format:nil];
  if (![engine startAndReturnError:nil]) return 1;
  // The reverb ignores a factory preset loaded before the engine starts (measured: every preset then
  // rendered identically), so it is chosen only once the engine is running.
  [reverb loadFactoryPreset:AVAudioUnitReverbPresetLargeHall2];
  reverb.wetDryMix = kReverbMixPercent;

  // Run until nothing has sounded for kRingOutSeconds (so the echo and reverb have died away) and no
  // event has arrived in that time. Any event, including one that arrives while winding down, keeps
  // the player alive, so no note is cut off.
  NSDate *silentSince = nil;
  for (;;) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    if (-lastEventAt.timeIntervalSinceNow >= kBedIdleSeconds) atomic_store(&bedWanted, false);
    if (!atomic_load(&everythingSilent)) {
      silentSince = nil;
      continue;
    }
    if (!silentSince) silentSince = [NSDate date];
    if (-silentSince.timeIntervalSinceNow >= kRingOutSeconds && -lastEventAt.timeIntervalSinceNow >= kRingOutSeconds) break;
  }
  // Stop taking events and release the lock before stopping the audio, so any later event starts a
  // new player instead of being sent to this one as it shuts down.
  [[NSDistributedNotificationCenter defaultCenter] removeObserver:observer];
  close(lockFd);
  [engine stop];
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
