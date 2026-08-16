"""Turn seven downloaded thunder recordings into game one-shots.

Five things are wrong with them as downloaded, and each one matters:

  1. Up to 2.9 s of silence before the strike. LightningDirector already
     delays thunder by distance / 343 -- baked-in silence reads to the player
     as extra distance, so a close bolt would sound a kilometre away.
  2. They run 18 to 40 seconds. A dust storm fires a strike every 3 to 7
     seconds; twelve overlapping 40-second rolls is mud, not weather.
  3. Stereo. These are positioned point sources in 3D, and a stereo source
     fights the engine's own panning.
  4. Mixed sample rates (one is 48 kHz).
  5. Peaks 7 dB apart, so the variation between clips would read as a volume
     bug rather than as different thunder.

Output: mono 44.1 kHz Ogg Vorbis, trimmed to the strike, level-matched
within each category.
"""
import os

import numpy as np
import scipy.signal as sig
import soundfile as sf

SRC = r"C:\Users\Mombo\Downloads"
DST = r"C:\Users\Mombo\Documents\! GODOT\route_41\assets"
SR = 44100

# Sorted by measured spectral centroid and crest factor, not by filename.
# "near" is what a bolt inside 160 m sounds like: a crack with a fast attack.
# "far" is the rolling low end you get from an in-cloud flash a kilometre or
# two off -- almost all of its energy below 300 Hz.
JOBS = [
    # (source, output stem, category)
    ("Pure-thunderclap.wav",            "thunder_near_01", "near"),
    ("thunder-blast.mp3",               "thunder_near_02", "near"),
    ("Powerful-single-peal-of-thunder.wav", "thunder_near_03", "near"),
    ("Thunder Crack.mp3",               "thunder_near_04", "near"),
    ("thunder-distant.mp3",             "thunder_far_01",  "far"),
    ("thunder-distant-3.mp3",           "thunder_far_02",  "far"),
    ("A-single-clap-of-thunder-in-woods-beside-a-lake.wav", "thunder_far_03", "far"),
]

# Near clips are cut short: the crack is the whole point and the tail is just
# occupying a voice. Far clips keep more roll, because the roll IS the sound.
LIMITS = {"near": (2.5, 5.5), "far": (4.0, 9.5)}
FADE_OUT = {"near": 0.45, "far": 0.90}

# Onset is measured on a 20 ms window against the LOUDEST window, not against
# the sample peak. Against the peak, a 26 dB crest transient drags the
# threshold so far down that a slow inaudible pre-rumble counts as the start --
# which left one clip with three and a half seconds of nothing in front of it.
HEAD_DB = -35.0
ONSET_WINDOW = 0.020
PRE_ROLL = 0.050    # keep this much before the onset so it is not clipped
# Longest run-up allowed before the loudest moment, per category. A near
# strike is the crack first and the roll after -- two of these recordings
# build for two seconds before the bang, which is what thunder from a mile off
# sounds like, not thunder from a hundred metres. Distant thunder is allowed a
# build, but a bounded one: the game already delays the clip by up to seven
# seconds for distance, and a further six-second swell inside the file
# disconnects the sound from the flash that caused it.
RUN_UP = {"near": 0.120, "far": 2.000}
FADE_IN = 0.003     # kills the click a hard cut would otherwise leave
TAIL_DB = -32.0     # a 200 ms window this far under the loudest is "over"
PEAK_CEILING = -1.0 # dBFS


def db(x):
    return 20.0 * np.log10(max(float(x), 1e-12))


def to_mono(x):
    """Average the channels, unless they are out of phase enough to cancel."""
    if x.shape[1] == 1:
        return x[:, 0]
    mono = x.mean(axis=1)
    loudest = max(np.abs(x[:, i]).max() for i in range(x.shape[1]))
    if db(np.abs(mono).max()) < db(loudest) - 3.0:
        # Phase cancellation. Keep the louder channel rather than a hollow sum.
        i = int(np.argmax([np.abs(x[:, c]).max() for c in range(x.shape[1])]))
        return x[:, i].copy()
    return mono


def window_rms(x, sr, seconds):
    w = max(int(seconds * sr), 1)
    if len(x) < w:
        return np.array([np.sqrt(np.mean(x ** 2))]), w
    frames = x[: (len(x) // w) * w].reshape(-1, w)
    return np.sqrt((frames ** 2).mean(axis=1)), w


def process(name, category):
    x, sr = sf.read(os.path.join(SRC, name), always_2d=True, dtype="float64")
    y = to_mono(x)

    # DC offset shows up as a thump on the fade-in and eats headroom.
    y -= y.mean()

    if sr != SR:
        g = np.gcd(int(sr), SR)
        y = sig.resample_poly(y, SR // g, sr // g)

    # --- head: cut to the onset ------------------------------------------
    onset_rms, ow = window_rms(y, SR, ONSET_WINDOW)
    thr = onset_rms.max() * 10 ** (HEAD_DB / 20.0)
    above = np.flatnonzero(onset_rms > thr)
    start = max(int(above[0]) * ow - int(PRE_ROLL * SR), 0) if len(above) else 0

    bang = int(np.argmax(onset_rms)) * ow
    start = max(start, bang - int(RUN_UP[category] * SR))
    y = y[start:]

    # --- tail: cut at a natural lull, inside the category's limits -----
    lo_s, hi_s = LIMITS[category]
    rms, w = window_rms(y, SR, 0.2)
    quiet = rms.max() * 10 ** (TAIL_DB / 20.0)
    peak_win = int(np.argmax(rms))
    end = len(y)
    for i in range(peak_win + 1, len(rms)):
        if rms[i] < quiet:
            end = (i + 1) * w
            break
    end = int(np.clip(end, lo_s * SR, hi_s * SR))
    end = min(end, len(y))
    y = y[:end]

    # --- fades ----------------------------------------------------------
    fi = min(int(FADE_IN * SR), len(y))
    y[:fi] *= np.linspace(0.0, 1.0, fi)
    fo = min(int(FADE_OUT[category] * SR), len(y))
    # Squared, so the tail dies away rather than ramping off linearly, which
    # is audible as a mixing-desk fader on broadband noise.
    y[-fo:] *= np.linspace(1.0, 0.0, fo) ** 2

    return y


def loudness(y):
    """RMS of the loudest 300 ms -- how loud the clip FEELS, not its peak."""
    rms, _ = window_rms(y, SR, 0.3)
    return float(rms.max())


def normalise(y, ceiling):
    """Scale so the peak sits exactly at the ceiling."""
    return y * (ceiling / max(np.abs(y).max(), 1e-12))


def limit_peak(y, ceiling):
    """Pull the peak down to the ceiling, but never push a quiet clip up.

    The distinction matters: normalising after a gain change would scale the
    clip straight back to full peak and undo the level match for anything that
    needed to come DOWN.
    """
    p = float(np.abs(y).max())
    return y * (ceiling / p) if p > ceiling else y


def soft_clip(y, knee_db=-9.0):
    """Round off anything above the knee instead of letting it clip.

    A thunderclap has a 26 dB crest factor: nearly all of its peak is one
    instantaneous transient sitting far above the body of the sound. Peak
    normalising such a clip leaves it audibly quieter than a flatter one
    normalised to the same peak, because the ear hears the body, not the
    spike. Rounding the spike is what lets the body come up to match.

    A static waveshaper rather than a real limiter, deliberately -- the
    harmonic distortion it adds is inaudible on broadband noise, which is
    exactly what thunder is, and it has no attack or release to ring.
    """
    knee = 10 ** (knee_db / 20.0)
    a = np.abs(y)
    over = a > knee
    if not over.any():
        return y
    out = y.copy()
    excess = (a[over] - knee) / (1.0 - knee)
    out[over] = np.sign(y[over]) * (knee + (1.0 - knee) * np.tanh(excess))
    return out


clips = {}
for src, stem, cat in JOBS:
    clips[stem] = (process(src, cat), cat, src)

# --- level match, per category ---------------------------------------------
# Matched on impact loudness, not on peak. Two passes, because rounding the
# transient changes the loudness it was aiming at; the second pass lands on it.
ceiling = 10 ** (PEAK_CEILING / 20.0)
for cat in ("near", "far"):
    members = [k for k, v in clips.items() if v[1] == cat]
    for k in members:
        y, c, s = clips[k]
        clips[k] = (normalise(y, ceiling), c, s)

    target = float(np.median([loudness(clips[k][0]) for k in members]))
    for _pass in range(2):
        for k in members:
            y, c, s = clips[k]
            gain = np.clip(target / max(loudness(y), 1e-12),
                           10 ** (-6.0 / 20.0), 10 ** (9.0 / 20.0))
            clips[k] = (limit_peak(soft_clip(y * gain), ceiling), c, s)

print(f"{'output':22s} {'cat':5s} {'len':>6s} {'peak':>7s} {'impact':>8s}  source")
for stem, (y, cat, src) in clips.items():
    path = os.path.join(DST, stem + ".ogg")
    sf.write(path, y.astype(np.float32), SR, format="OGG", subtype="VORBIS")
    size = os.path.getsize(path) / 1024.0
    print(f"{stem + '.ogg':22s} {cat:5s} {len(y) / SR:5.2f}s "
          f"{db(np.abs(y).max()):6.1f}dB {db(loudness(y)):7.1f}dB  "
          f"{size:6.0f} KB  <- {src}")
