/*
 * lvol — logarithmic (dB-uniform) output volume control for macOS.
 *
 * Why: the macOS volume slider is (very close to) LINEAR in amplitude.
 * Near the bottom, one percentage step is a huge jump in perceived loudness,
 * so it is impossible to fine-tune quiet levels. lvol exposes a perceptual
 * (dB) scale and drives the device's floating-point volume scalar directly,
 * which also reaches levels far below the lowest non-zero slider position.
 *
 * Build:  clang -O2 -o lvol lvol.c -framework CoreAudio -framework AudioToolbox
 * License: MIT
 */

#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Present in modern SDKs; kept as a guard for older toolchains. 'vmvc' */
#ifndef kAudioHardwareServiceDeviceProperty_VirtualMainVolume
#define kAudioHardwareServiceDeviceProperty_VirtualMainVolume 'vmvc'
#endif

#define DEFAULT_RANGE_DB 60.0 /* level 0 -> -60 dB, level 100 -> 0 dB */
#define MIN_SCALAR 1e-7f      /* ~ -140 dB, effectively silence */

/* ------------------------------------------------------------------ */
/* small CoreAudio helpers                                             */
/* ------------------------------------------------------------------ */

static AudioObjectPropertyAddress make_addr(AudioObjectPropertySelector sel,
                                            AudioObjectPropertyScope scope,
                                            AudioObjectPropertyElement el) {
    AudioObjectPropertyAddress a;
    a.mSelector = sel;
    a.mScope = scope;
    a.mElement = el;
    return a;
}

static int has_prop(AudioDeviceID dev, AudioObjectPropertyAddress a) {
    return AudioObjectHasProperty(dev, &a) ? 1 : 0;
}

static int get_f32(AudioDeviceID dev, AudioObjectPropertyAddress a, Float32 *out) {
    if (!has_prop(dev, a)) return 0;
    UInt32 size = sizeof(Float32);
    return AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, out) == noErr ? 1 : 0;
}

static int set_f32(AudioDeviceID dev, AudioObjectPropertyAddress a, Float32 v) {
    if (!has_prop(dev, a)) return 0;
    return AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(Float32), &v) == noErr ? 1 : 0;
}

/* Candidate properties for the "main" output volume, best first. */
static AudioObjectPropertyAddress vol_candidates[3];
static int vol_candidate_count = 0;

static void init_vol_candidates(void) {
    vol_candidate_count = 0;
    vol_candidates[vol_candidate_count++] =
        make_addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                  kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain);
    vol_candidates[vol_candidate_count++] =
        make_addr(kAudioDevicePropertyVolumeScalar,
                  kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain);
    vol_candidates[vol_candidate_count++] =
        make_addr(kAudioDevicePropertyVolumeScalar,
                  kAudioObjectPropertyScopeOutput, (AudioObjectPropertyElement)1);
}

static int read_volume(AudioDeviceID dev, Float32 *out) {
    for (int i = 0; i < vol_candidate_count; i++)
        if (get_f32(dev, vol_candidates[i], out)) return 1;
    return 0;
}

static int write_volume(AudioDeviceID dev, Float32 v) {
    for (int i = 0; i < vol_candidate_count; i++)
        if (set_f32(dev, vol_candidates[i], v)) return 1;
    return 0;
}

static int read_mute(AudioDeviceID dev, UInt32 *out) {
    AudioObjectPropertyAddress a =
        make_addr(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput,
                  kAudioObjectPropertyElementMain);
    if (has_prop(dev, a)) {
        UInt32 size = sizeof(UInt32);
        if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, out) == noErr) return 1;
    }
    a.mElement = (AudioObjectPropertyElement)1;
    if (has_prop(dev, a)) {
        UInt32 size = sizeof(UInt32);
        if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, out) == noErr) return 1;
    }
    *out = 0;
    return 0;
}

static int write_mute(AudioDeviceID dev, UInt32 v) {
    AudioObjectPropertyAddress a =
        make_addr(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput,
                  kAudioObjectPropertyElementMain);
    if (has_prop(dev, a) &&
        AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(UInt32), &v) == noErr)
        return 1;
    a.mElement = (AudioObjectPropertyElement)1;
    if (has_prop(dev, a) &&
        AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(UInt32), &v) == noErr)
        return 1;
    return 0;
}

/* ------------------------------------------------------------------ */
/* device discovery                                                    */
/* ------------------------------------------------------------------ */

static AudioDeviceID default_output(void) {
    AudioObjectPropertyAddress a =
        make_addr(kAudioHardwarePropertyDefaultOutputDevice,
                  kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
    AudioDeviceID dev = kAudioObjectUnknown;
    UInt32 size = sizeof(AudioDeviceID);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, &dev);
    return dev;
}

static int device_has_output(AudioDeviceID dev) {
    AudioObjectPropertyAddress a = make_addr(kAudioDevicePropertyStreamConfiguration,
                                             kAudioObjectPropertyScopeOutput,
                                             kAudioObjectPropertyElementMain);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &size) != noErr) return 0;
    if (size == 0) return 0;
    AudioBufferList *bl = (AudioBufferList *)malloc(size);
    if (!bl) return 0;
    int ok = 0;
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, bl) == noErr) {
        for (UInt32 i = 0; i < bl->mNumberBuffers; i++)
            if (bl->mBuffers[i].mNumberChannels > 0) ok = 1;
    }
    free(bl);
    return ok;
}

static void device_name(AudioDeviceID dev, char *buf, size_t n) {
    AudioObjectPropertyAddress a = make_addr(kAudioObjectPropertyName,
                                             kAudioObjectPropertyScopeGlobal,
                                             kAudioObjectPropertyElementMain);
    CFStringRef cf = NULL;
    UInt32 size = sizeof(CFStringRef);
    buf[0] = '\0';
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &cf) == noErr && cf) {
        CFStringGetCString(cf, buf, (CFIndex)n, kCFStringEncodingUTF8);
        CFRelease(cf);
    }
}

static int name_contains_ci(const char *hay, const char *needle) {
    size_t hn = strlen(hay), nn = strlen(needle);
    if (nn == 0 || nn > hn) return 0;
    for (size_t i = 0; i + nn <= hn; i++) {
        size_t j = 0;
        for (; j < nn; j++) {
            char a = hay[i + j], b = needle[j];
            if (a >= 'A' && a <= 'Z') a += 32;
            if (b >= 'A' && b <= 'Z') b += 32;
            if (a != b) break;
        }
        if (j == nn) return 1;
    }
    return 0;
}

/* Resolve a device by name substring (case-insensitive) among output devices. */
static AudioDeviceID find_output_by_name(const char *needle, int *ambiguous) {
    AudioObjectPropertyAddress a = make_addr(kAudioHardwarePropertyDevices,
                                             kAudioObjectPropertyScopeGlobal,
                                             kAudioObjectPropertyElementMain);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size) != noErr)
        return kAudioObjectUnknown;
    int n = (int)(size / sizeof(AudioDeviceID));
    AudioDeviceID *devs = (AudioDeviceID *)malloc(size);
    if (!devs) return kAudioObjectUnknown;
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, devs);

    AudioDeviceID match = kAudioObjectUnknown;
    int count = 0;
    char name[256];
    for (int i = 0; i < n; i++) {
        if (!device_has_output(devs[i])) continue;
        device_name(devs[i], name, sizeof(name));
        if (name_contains_ci(name, needle)) {
            if (match == kAudioObjectUnknown) match = devs[i];
            count++;
        }
    }
    free(devs);
    if (ambiguous) *ambiguous = count > 1;
    return match;
}

static void list_outputs(void) {
    AudioObjectPropertyAddress a = make_addr(kAudioHardwarePropertyDevices,
                                             kAudioObjectPropertyScopeGlobal,
                                             kAudioObjectPropertyElementMain);
    UInt32 size = 0;
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size);
    int n = (int)(size / sizeof(AudioDeviceID));
    AudioDeviceID *devs = (AudioDeviceID *)malloc(size);
    if (!devs) return;
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, devs);

    AudioDeviceID def = default_output();
    char name[256];
    printf("output devices:\n");
    for (int i = 0; i < n; i++) {
        if (!device_has_output(devs[i])) continue;
        device_name(devs[i], name, sizeof(name));
        Float32 v;
        char volstr[32] = "  n/a";
        if (read_volume(devs[i], &v))
            snprintf(volstr, sizeof(volstr), "%5.1f%%", v * 100.0);
        printf("  %c [%u] %-40s %s\n", devs[i] == def ? '*' : ' ', (unsigned)devs[i],
               name, volstr);
    }
    free(devs);
}

/* ------------------------------------------------------------------ */
/* perceptual <-> amplitude mapping                                    */
/* ------------------------------------------------------------------ */

/* level 0..100 -> amplitude scalar, uniform in dB */
static Float32 level_to_scalar(double level, double range_db) {
    if (level < 0) level = 0;
    if (level > 100) level = 100;
    double db = (level / 100.0 - 1.0) * range_db; /* 100 -> 0 dB, 0 -> -range */
    double s = pow(10.0, db / 20.0);
    if (s < MIN_SCALAR) s = MIN_SCALAR;
    if (s > 1.0) s = 1.0;
    return (Float32)s;
}

/* amplitude scalar -> level 0..100 (inverse of the above) */
static double scalar_to_level(Float32 scalar, double range_db) {
    if (scalar <= 0) return 0.0;
    double db = 20.0 * log10((double)scalar);
    if (db > 0) db = 0;
    double level = 100.0 * (1.0 + db / range_db);
    if (level < 0) level = 0;
    if (level > 100) level = 100;
    return level;
}

static double scalar_to_db(Float32 scalar) {
    if (scalar <= 0) return -INFINITY;
    return 20.0 * log10((double)scalar);
}

/* ------------------------------------------------------------------ */
/* cli                                                                 */
/* ------------------------------------------------------------------ */

static void usage(void) {
    printf(
        "lvol — logarithmic (dB-uniform) output volume for macOS\n"
        "\n"
        "usage:\n"
        "  lvol                     show current volume\n"
        "  lvol <0-100>             set perceptual level (equal steps = equal dB)\n"
        "  lvol +N | -N             raise / lower level by N (relative)\n"
        "  lvol <dB>dB              set absolute gain, e.g. -30dB (0dB = max)\n"
        "  lvol mute | unmute       toggle mute\n"
        "  lvol list                list output devices\n"
        "\n"
        "options:\n"
        "  -d, --device <name>      target device by (substring) name\n"
        "  -r, --range <dB>         dB span of the 0-100 scale (default %.0f)\n"
        "  -h, --help               this help\n"
        "\n"
        "The macOS slider is linear in amplitude, so its low end is coarse.\n"
        "lvol uses a dB scale and writes the device's float volume scalar,\n"
        "reaching levels the slider cannot.\n",
        DEFAULT_RANGE_DB);
}

int main(int argc, char **argv) {
    init_vol_candidates();

    const char *device_sel = NULL;
    const char *value = NULL;
    double range_db = DEFAULT_RANGE_DB;
    int do_list = 0;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "-h") || !strcmp(a, "--help")) {
            usage();
            return 0;
        } else if (!strcmp(a, "-d") || !strcmp(a, "--device")) {
            if (i + 1 >= argc) { fprintf(stderr, "lvol: -d needs a device name\n"); return 2; }
            device_sel = argv[++i];
        } else if (!strcmp(a, "-r") || !strcmp(a, "--range")) {
            if (i + 1 >= argc) { fprintf(stderr, "lvol: -r needs a number\n"); return 2; }
            range_db = atof(argv[++i]);
            if (range_db <= 0) { fprintf(stderr, "lvol: range must be > 0\n"); return 2; }
        } else if (!strcmp(a, "list") || !strcmp(a, "--list")) {
            do_list = 1;
        } else if (!value) {
            value = a;
        } else {
            fprintf(stderr, "lvol: unexpected argument '%s'\n", a);
            return 2;
        }
    }

    if (do_list) {
        list_outputs();
        return 0;
    }

    AudioDeviceID dev = kAudioObjectUnknown;
    if (device_sel) {
        int ambiguous = 0;
        dev = find_output_by_name(device_sel, &ambiguous);
        if (dev == kAudioObjectUnknown) {
            fprintf(stderr, "lvol: no output device matching '%s'\n", device_sel);
            return 1;
        }
        if (ambiguous)
            fprintf(stderr, "lvol: warning: several devices match '%s', using first\n",
                    device_sel);
    } else {
        dev = default_output();
        if (dev == kAudioObjectUnknown) {
            fprintf(stderr, "lvol: no default output device\n");
            return 1;
        }
    }

    char dname[256];
    device_name(dev, dname, sizeof(dname));

    /* ---- show ---- */
    if (!value) {
        Float32 s = 0;
        UInt32 muted = 0;
        if (!read_volume(dev, &s)) {
            fprintf(stderr, "lvol: cannot read volume of '%s'\n", dname);
            return 1;
        }
        read_mute(dev, &muted);
        double level = scalar_to_level(s, range_db);
        double db = scalar_to_db(s);
        printf("%-24s  level %5.1f/100   %+6.1f dB   amp %6.3f%%%s\n", dname, level, db,
               s * 100.0, muted ? "   [muted]" : "");
        return 0;
    }

    /* ---- mute ---- */
    if (!strcmp(value, "mute")) {
        if (!write_mute(dev, 1)) { fprintf(stderr, "lvol: mute not supported\n"); return 1; }
        printf("%s: muted\n", dname);
        return 0;
    }
    if (!strcmp(value, "unmute")) {
        write_mute(dev, 0);
        printf("%s: unmuted\n", dname);
        return 0;
    }

    /* ---- compute target scalar ---- */
    Float32 target;
    size_t vlen = strlen(value);
    int is_db = 0;
    if (vlen > 2 &&
        (value[vlen - 2] == 'd' || value[vlen - 2] == 'D') &&
        (value[vlen - 1] == 'b' || value[vlen - 1] == 'B'))
        is_db = 1;

    if (is_db) {
        double db = atof(value); /* trailing "dB" ignored by atof */
        double s = pow(10.0, db / 20.0);
        if (s < MIN_SCALAR) s = MIN_SCALAR;
        if (s > 1.0) s = 1.0;
        target = (Float32)s;
    } else if (value[0] == '+' || value[0] == '-') {
        Float32 cur = 0;
        if (!read_volume(dev, &cur)) { fprintf(stderr, "lvol: cannot read current volume\n"); return 1; }
        double cur_level = scalar_to_level(cur, range_db);
        double delta = atof(value); /* includes sign */
        double new_level = cur_level + delta;
        if (new_level < 0) new_level = 0;
        if (new_level > 100) new_level = 100;
        target = level_to_scalar(new_level, range_db);
    } else {
        char *end = NULL;
        double lv = strtod(value, &end);
        if (end == value) {
            fprintf(stderr, "lvol: invalid value '%s' (see --help)\n", value);
            return 2;
        }
        target = level_to_scalar(lv, range_db);
    }

    if (!write_volume(dev, target)) {
        fprintf(stderr, "lvol: cannot set volume of '%s'\n", dname);
        return 1;
    }

    double level = scalar_to_level(target, range_db);
    double db = scalar_to_db(target);
    printf("%-24s  level %5.1f/100   %+6.1f dB   amp %6.3f%%\n", dname, level, db,
           target * 100.0);
    return 0;
}
