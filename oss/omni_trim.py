#!/usr/bin/env python3
"""Leaves out of GeckoView's omni.ja the parts no Wayward user can reach.

    python3 tools/omni_trim.py trim <omni.ja> <trimmed omni.ja>
    python3 tools/omni_trim.py list <omni.ja>

omni.ja is the archive of the engine's own scripts, pages and texts, and comes inside GeckoView (Mozilla, MPL-2.0).
Gradle runs "trim" on the merged assets of release and qa builds (app/build.gradle.kts, trim<Variant>OmniJa); debug
builds ship Mozilla's archive as it came. "list" prints what "trim" leaves out, with each entry's bytes stored and
unpacked. No file inside is changed: entries are left out whole, and the rest is copied byte for byte in the same
order, so the same GeckoView gives the same archive. THIRD_PARTY_NOTICES.md and the app's own notice say the archive
is a trimmed one; this script is the record of what goes.

What goes (LEFT_OUT), and why nobody misses it:

- The engine's developer tools server (chrome/devtools/modules): it runs only for remote debugging, which Wayward
  never turns on in any build (GeckoRuntimeSettings.remoteDebuggingEnabled), and for the test-automation agent
  (chrome/remote), which is never started.
- Settings for CPUs Wayward isn't built for (armeabi-v7a, x86_64): Wayward ships arm64-v8a only.
- The engine's own about: pages for developers and support staff (about:support, about:memory, about:telemetry and
  the rest of ABOUT_PAGES), their styles, and their texts in 99 languages. Wayward opens web addresses only: a typed
  or shared about: address becomes a search (Urls.kt, Engine.loadUntrusted), and the engine itself refuses a web
  page's link to any of these. The pages a web page may link to or the engine shows by itself stay: about:blank,
  about:license (Mozilla's license notices), about:mozilla, about:buildconfig, about:checkerboard, the error pages,
  the certificate viewer, the reader, the PDF viewer, translations.

It stops, and the build with it, when a rule matches nothing (GeckoView moved or renamed something: look again), or
when a file that stays names one that goes (STILL_NAMED_BY lists the known ones that never run in Wayward). Either
means a GeckoView update changed what this script knows: docs/DEPENDENCY_UPDATES.md, GeckoView.
"""
import fnmatch
import os
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zip_without import copy_without  # noqa: E402

ABOUT_PAGES = [
    # about:about, about:logging, about:memory, about:networking, about:processes, about:serviceworkers,
    # about:support, about:sync-log, about:telemetry, about:url-classifier, about:webrtc, about:crashes
    "aboutAbout.*", "aboutLogging/*", "aboutMemory.*", "aboutNetworking.*", "aboutProcesses.*",
    "aboutServiceWorkers.*", "aboutSupport.*", "aboutSyncLog.*", "aboutTelemetry.*", "aboutUrlClassifier.*",
    "aboutwebrtc/*", "crashes.*",
]
ABOUT_TEXTS = [
    "toolkit/about/aboutAbout.ftl", "toolkit/about/aboutLogging.ftl", "toolkit/about/aboutNetworking.ftl",
    "toolkit/about/aboutProcesses.ftl", "toolkit/about/aboutServiceWorkers.ftl", "toolkit/about/aboutSupport.ftl",
    "toolkit/about/aboutTelemetry.ftl", "toolkit/about/url-classifier.ftl", "toolkit/about/aboutWebrtc.ftl",
    "services/aboutSyncLog.ftl", "crashreporter/aboutcrashes.ftl", "mobile/android/aboutConfig.ftl",
]

# (what it is, the entries: shell patterns where * also crosses folders)
LEFT_OUT = [
    ("developer tools server", ["chrome/devtools/modules/*"]),
    ("other CPUs' settings", ["armeabi-v7a/*", "x86_64/*", "defaults/pref/armeabi-v7a/*", "defaults/pref/x86_64/*"]),
    ("about: pages nobody can open",
     ["chrome/toolkit/content/global/" + p for p in ABOUT_PAGES]
     + ["chrome/geckoview/content/config.js", "chrome/geckoview/content/config.xhtml",  # about:config
        "chrome/toolkit/skin/classic/global/aboutMemory.css"]),
    ("those pages' texts, in every language", ["localization/*/" + t for t in ABOUT_TEXTS]),
]

# Files that stay and name something that goes, each for a use that never happens in Wayward:
# the test-automation agent and the remote debugger (never started), a manifest's folder names, a comparison with
# the JSON viewer's address (GeckoView has no JSON viewer), a type named in a comment, a task runner for desktop, and
# each language's count of translated texts, which nothing in the archive reads.
STILL_NAMED_BY = [
    "localization/*/coverage.json",
    "chrome/remote/*", "modules/GeckoViewRemoteDebugger.sys.mjs", "chrome/chrome.manifest",
    "chrome/toolkit/content/global/contentAreaUtils.js", "modules/ExtensionParent.sys.mjs",
    "modules/BackgroundTasksManager.sys.mjs",
]


def names_for(entry):
    """The texts a file would hold if it used this entry."""
    for folder, address in (
        ("chrome/devtools/modules/devtools/", "resource://devtools/"),
        ("chrome/toolkit/content/global/", "chrome://global/content/"),
        ("chrome/toolkit/skin/classic/global/", "chrome://global/skin/"),
        ("chrome/geckoview/content/", "chrome://geckoview/content/"),
    ):
        if entry.startswith(folder):
            return [address + entry[len(folder):]]
    if entry.startswith("localization/"):
        return [entry.split("/", 2)[2]]
    return []


def plan(archive):
    with zipfile.ZipFile(archive) as z:
        infos = z.infolist()
        entries = [i.filename for i in infos]
        out = {}
        for what, patterns in LEFT_OUT:
            for pattern in patterns:
                hit = [e for e in entries if fnmatch.fnmatchcase(e, pattern)]
                if not hit:
                    sys.exit(f"omni_trim: nothing in {archive} matches {pattern} ({what}). GeckoView changed: "
                             "look at the archive again before trimming it (docs/DEPENDENCY_UPDATES.md).")
                out.update((e, what) for e in hit)
        wanted = {}
        for entry in out:
            for text in names_for(entry):
                wanted[text.encode()] = entry
        # The developer tools as a whole, so a new file of theirs is covered too.
        wanted[b"resource://devtools/"] = "chrome/devtools/modules/*"
        problems = []
        for info in infos:
            name = info.filename
            if name in out or any(fnmatch.fnmatchcase(name, p) for p in STILL_NAMED_BY):
                continue
            data = z.read(info)
            for text, entry in wanted.items():
                if text in data and len(problems) < 40:
                    problems.append(f"{name} names {text.decode()} ({entry} is left out)")
        if problems:
            sys.exit("omni_trim: files that stay name files that go. GeckoView changed: check that Wayward never "
                     "runs them, then add them to STILL_NAMED_BY, or keep what they name:\n  " + "\n  ".join(problems))
        sizes = {i.filename: (i.compress_size, i.file_size) for i in infos}
    return out, sizes


def main(args):
    if len(args) == 2 and args[0] == "list":
        out, sizes = plan(args[1])
    elif len(args) == 3 and args[0] == "trim":
        out, sizes = plan(args[1])
        copy_without(args[1], args[2], set(out))
    else:
        sys.exit(__doc__)
    for what, _ in LEFT_OUT:
        mine = sorted(e for e, w in out.items() if w == what)
        if args[0] == "list":
            for e in mine:
                print(f"{e}\t{sizes[e][0]}\t{sizes[e][1]}")
        print(f"omni_trim: {what}: {len(mine)} entries, {sum(sizes[e][0] for e in mine)} bytes stored, "
              f"{sum(sizes[e][1] for e in mine)} unpacked")
    if args[0] == "trim":
        print(f"omni_trim: omni.ja {os.path.getsize(args[1])} -> {os.path.getsize(args[2])} bytes, "
              f"{len(out)} of {len(sizes)} entries left out")


if __name__ == "__main__":
    main(sys.argv[1:])
