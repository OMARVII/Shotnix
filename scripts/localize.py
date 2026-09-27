#!/usr/bin/env python3
"""Keeps Shotnix's String Catalog in step with the code, and compiles it.

    python3 scripts/localize.py          # sync + compile (writes files)
    python3 scripts/localize.py --check  # verify only; exits 1 on problems
    python3 scripts/localize.py --clean  # rebuild the extraction from scratch

What it does:
1. Builds ShotnixCore with the compiler's string extraction (in its own
   scratch folder, so the normal build isn't invalidated). Every `L("…")`
   call becomes a key, exactly as Foundation will look it up ("%lld captures").
2. Writes Localization/Localizable.xcstrings: every extracted key, English as
   the source language. Translations come from the catalog itself, overridden
   by Localization/translations/*.json (one file per area of the app, so work
   on different areas never conflicts). Keys the code no longer uses are
   dropped.
3. Compiles the catalog with Apple's xcstringstool into
   Sources/ShotnixCore/Resources/<language>.lproj, and writes the main
   bundle's InfoPlist.strings (Localization/Main/<language>.lproj) from
   Localization/InfoPlist.json.

A translation file maps English keys to translations. A plural takes a
dictionary of CLDR categories (zero/one/two/few/many/other):

    {
      "Save changes to this screenshot?": {
        "comment": "Alert title when closing the editor with unsaved edits",
        "de": "Änderungen an diesem Bildschirmfoto sichern?",
        "fr": "Enregistrer les modifications de cette capture ?",
        "zh-Hans": "要存储对此截屏的更改吗？"
      },
      "%lld captures": {
        "en": {"one": "%lld capture", "other": "%lld captures"},
        "de": {"one": "%lld Aufnahme", "other": "%lld Aufnahmen"},
        "fr": {"one": "%lld capture", "other": "%lld captures"},
        "zh-Hans": "%lld 张截图"
      }
    }
"""
import collections
import filecmp
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCALIZATION = os.path.join(ROOT, "Localization")
CATALOG = os.path.join(LOCALIZATION, "Localizable.xcstrings")
TRANSLATIONS = os.path.join(LOCALIZATION, "translations")
INFOPLIST_SOURCE = os.path.join(LOCALIZATION, "InfoPlist.json")
MAIN_LPROJ = os.path.join(LOCALIZATION, "Main")
RESOURCES = os.path.join(ROOT, "Sources", "ShotnixCore", "Resources")
SOURCES = os.path.join(ROOT, "Sources", "ShotnixCore")
SCRATCH = os.path.join(ROOT, ".build", "l10n")
LANGUAGES = ["de", "fr", "zh-Hans", "ru", "uk"]
# Plural forms each language needs for whole numbers (CLDR). Russian and
# Ukrainian: 1 день, 2 дня, 5 дней; "other" covers fractions.
REQUIRED_PLURALS = {"ru": {"one", "few", "many", "other"}, "uk": {"one", "few", "many", "other"}}
PLURAL_CATEGORIES = ["zero", "one", "two", "few", "many", "other"]

SPECIFIER = re.compile(r"%(?:\d+\$)?(?:[-+ 0#]*\d*(?:\.\d+)?)(?:ll|l|h|hh|q|z|t|j)?([@dDuUxXoOfFeEgGcCsSaAp])|%%")


def specifiers(text):
    """Format specifiers by type, ignoring positions ("%1$@" is "@")."""
    found = []
    for match in SPECIFIER.finditer(text):
        if match.group(0) == "%%":
            continue
        kind = match.group(1)
        length = re.search(r"(ll|l|q)?[@dDuUxXoOfFeEgGcCsSaAp]$", match.group(0)).group(0)
        found.append(length if kind != "@" else "@")
    return collections.Counter(found)


def extract_keys():
    """Every localized string in ShotnixCore, from the compiler: key -> comment."""
    # Kept between runs: an incremental build only re-emits the files it
    # recompiles, and each file's data replaces its previous run's.
    strings_dir = os.path.join(SCRATCH, "strings")
    if "--clean" in sys.argv:
        shutil.rmtree(SCRATCH, ignore_errors=True)
    os.makedirs(strings_dir, exist_ok=True)
    command = [
        "swift", "build", "--target", "ShotnixCore", "--scratch-path", SCRATCH,
        "-Xswiftc", "-emit-localized-strings",
        "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", strings_dir,
    ]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stdout[-4000:] + result.stderr[-4000:])
        sys.exit("✗ Extraction build failed")
    keys = {}
    for path in glob.glob(os.path.join(strings_dir, "**", "*.stringsdata"), recursive=True):
        data = json.load(open(path, encoding="utf-8"))
        source = data.get("source", "")
        if not os.path.realpath(source).startswith(os.path.realpath(SOURCES)):
            continue  # dependencies localize themselves
        if not os.path.exists(source):
            os.remove(path)  # the file was deleted or renamed
            continue
        for table, entries in data.get("tables", {}).items():
            if table != "Localizable":
                sys.exit(f"✗ {source}: strings must use L(…), not table {table!r}")
            for entry in entries:
                keys.setdefault(entry["key"], entry.get("comment") or "")
    return keys


def load_catalog():
    if not os.path.exists(CATALOG):
        return {}
    return json.load(open(CATALOG, encoding="utf-8")).get("strings", {})


def catalog_value(unit):
    """A catalog localization as a string or a plural dictionary."""
    if "stringUnit" in unit:
        return unit["stringUnit"]["value"]
    plural = unit.get("variations", {}).get("plural")
    if plural:
        return {category: plural[category]["stringUnit"]["value"] for category in plural}
    return None


def load_translations():
    merged = {}
    for path in sorted(glob.glob(os.path.join(TRANSLATIONS, "*.json"))):
        data = json.load(open(path, encoding="utf-8"))
        for key, entry in data.items():
            if key in merged and merged[key] != entry:
                previous = merged[key]
                for field, value in entry.items():
                    if field in previous and previous[field] != value and field != "comment":
                        sys.exit(f"✗ {os.path.basename(path)}: {key!r} is translated differently in another file ({field})")
                previous.update(entry)
            else:
                merged[key] = dict(entry)
    return merged


def french_typography(text):
    """No-break spaces where French typography puts them: before ? ! : ; and inside « »."""
    text = re.sub(r" ([?!:;])", "\u00a0\\1", text)
    return text.replace("« ", "«\u00a0").replace(" »", "\u00a0»")


def typeset(language, value):
    if language != "fr":
        return value
    if isinstance(value, dict):
        return {category: french_typography(text) for category, text in value.items()}
    return french_typography(value)


def unit_for(value):
    if isinstance(value, dict):
        return {"variations": {"plural": {
            category: {"stringUnit": {"state": "translated", "value": value[category]}}
            for category in PLURAL_CATEGORIES if category in value
        }}}
    return {"stringUnit": {"state": "translated", "value": value}}


def build_catalog(keys, existing, translations):
    strings = {}
    for key in sorted(keys, key=lambda k: (k.lower(), k)):
        old = existing.get(key, {})
        new = translations.get(key, {})
        entry = {}
        comment = new.get("comment") or old.get("comment") or keys[key]
        if comment:
            entry["comment"] = comment
        localizations = {}
        for language in ["en"] + LANGUAGES:
            value = new.get(language)
            if value is None and language in old.get("localizations", {}):
                value = catalog_value(old["localizations"][language])
            if value is not None:
                localizations[language] = unit_for(typeset(language, value))
        if localizations:
            entry["localizations"] = localizations
        strings[key] = entry
    return {"sourceLanguage": "en", "strings": strings, "version": "1.0"}


def needs_translation(key):
    """Strings with words; placeholders and punctuation alone ("%@ — %@") stay as they are."""
    return re.search(r"[^\W\d_]", SPECIFIER.sub("", key)) is not None


def problems_in(catalog):
    problems = []
    for key, entry in catalog["strings"].items():
        if not needs_translation(key):
            continue
        expected = specifiers(key)
        english = entry.get("localizations", {}).get("en")
        if english:
            for text in values_of(catalog_value(english)):
                if not specifiers(text) <= expected:
                    problems.append(f"{key!r} (en): placeholders {dict(specifiers(text))} don't match {dict(expected)}")
        for language in LANGUAGES:
            unit = entry.get("localizations", {}).get(language)
            value = catalog_value(unit) if unit else None
            if value in (None, "", {}):
                problems.append(f"{key!r}: no {language} translation")
                continue
            plural = isinstance(value, dict)
            if plural and "other" not in value:
                problems.append(f"{key!r} ({language}): a plural needs an 'other' form")
            if plural and not REQUIRED_PLURALS.get(language, set()) <= set(value):
                missing = sorted(REQUIRED_PLURALS[language] - set(value))
                problems.append(f"{key!r} ({language}): a plural needs the {', '.join(missing)} forms")
            for text in values_of(value):
                found = specifiers(text)
                if plural:
                    ok = found <= expected
                else:
                    ok = found == expected
                if not ok:
                    problems.append(f"{key!r} ({language}): placeholders {dict(found)} don't match {dict(expected)} in {text!r}")
    return problems


def values_of(value):
    return list(value.values()) if isinstance(value, dict) else [value]


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2, separators=(",", " : "), sort_keys=True)
        handle.write("\n")


def compile_catalog(catalog_path, output):
    result = subprocess.run(["xcrun", "xcstringstool", "compile", catalog_path, "--output-directory", output],
                            capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stdout + result.stderr)
        sys.exit("✗ xcstringstool compile failed")


def write_infoplist_strings(output):
    source = json.load(open(INFOPLIST_SOURCE, encoding="utf-8"))
    for language in ["en"] + LANGUAGES:
        lines = []
        for key in sorted(source):
            value = source[key].get(language)
            if value is None:
                sys.exit(f"✗ InfoPlist.json: {key} has no {language} value")
            escaped = value.replace("\\", "\\\\").replace('"', '\\"')
            lines.append(f'"{key}" = "{escaped}";')
        path = os.path.join(output, f"{language}.lproj", "InfoPlist.strings")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")


def same_tree(a, b):
    comparison = filecmp.dircmp(a, b)
    if comparison.left_only or comparison.right_only or comparison.diff_files or comparison.funny_files:
        return False
    return all(same_tree(os.path.join(a, sub), os.path.join(b, sub)) for sub in comparison.common_dirs)


def lproj_dirs(folder):
    return sorted(d for d in os.listdir(folder) if d.endswith(".lproj")) if os.path.isdir(folder) else []


def main():
    check = "--check" in sys.argv
    keys = extract_keys()
    catalog = build_catalog(keys, load_catalog(), load_translations())
    problems = problems_in(catalog)

    with tempfile.TemporaryDirectory() as temp:
        catalog_path = os.path.join(temp, "Localizable.xcstrings")
        write_json(catalog_path, catalog)
        compiled = os.path.join(temp, "compiled")
        compile_catalog(catalog_path, compiled)
        main_lproj = os.path.join(temp, "main")
        write_infoplist_strings(main_lproj)

        if check:
            stale = []
            if not os.path.exists(CATALOG) or not filecmp.cmp(catalog_path, CATALOG, shallow=False):
                stale.append("Localization/Localizable.xcstrings")
            committed = tempfile.mkdtemp(dir=temp)
            for name in lproj_dirs(RESOURCES):
                shutil.copytree(os.path.join(RESOURCES, name), os.path.join(committed, name))
            if not same_tree(compiled, committed):
                stale.append("Sources/ShotnixCore/Resources/*.lproj")
            if not os.path.isdir(MAIN_LPROJ) or not same_tree(main_lproj, MAIN_LPROJ):
                stale.append("Localization/Main")
            for problem in problems:
                print("✗", problem)
            for path in stale:
                print(f"✗ {path} is out of date: run python3 scripts/localize.py")
            print(f"{len(keys)} strings, {len(problems)} problems")
            sys.exit(1 if problems or stale else 0)

        write_json(CATALOG, catalog)
        for name in lproj_dirs(RESOURCES):
            shutil.rmtree(os.path.join(RESOURCES, name))
        for name in lproj_dirs(compiled):
            shutil.copytree(os.path.join(compiled, name), os.path.join(RESOURCES, name))
        shutil.rmtree(MAIN_LPROJ, ignore_errors=True)
        shutil.copytree(main_lproj, MAIN_LPROJ)

    missing = collections.Counter(p.split(": no ")[1].split()[0] for p in problems if ": no " in p)
    other = [p for p in problems if ": no " not in p]
    translatable = sum(1 for key in keys if needs_translation(key))
    print(f"✓ {len(keys)} strings in the catalog ({translatable} to translate)")
    for language in LANGUAGES:
        print(f"  {language}: {translatable - missing[language]} translated, {missing[language]} missing")
    for problem in other:
        print("✗", problem)
    sys.exit(1 if other else 0)


if __name__ == "__main__":
    main()
