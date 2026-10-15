"""Recall's translations (app/Sources/Localization.swift, app/Resources/Localizations/*.json).

Every L("…") in the app has a translation in each language, with the same {0}, {1}… values and
the same bold text; no translation is left over from text the app no longer shows; the Info.plist
strings match the build's; build_native_app.py writes readable .strings files; and no on-screen
text or other sentence in the app skips L. Deterministic: no app build, runtime or game (the bold
check compiles a small Swift program when swiftc is there).
"""
import json
import plistlib
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'scripts'))
import build_native_app  # noqa: E402

SOURCES = sorted((ROOT/'app/Sources').glob('*.swift'))
LANGUAGES = sorted((ROOT/'app/Resources/Localizations').glob('*.json'))
LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
# Where a string reaches the screen: SwiftUI views and modifiers, AppKit menus and alerts, and
# the app's own components and helpers that take on-screen text.
ON_SCREEN = re.compile(r'\b(?:Text|Button|Label|Link|Toggle|Picker)\(|\.help\(|\.accessibility(?:Label|Hint|Value)\(|\.alert\('
                       r'|\b(?:title|subtitle|detail|text|button|message):|\b(?:notice|stage|messageText|informativeText|prompt)\s*=(?!=)'
                       r'|addButton\(withTitle:|NSMenuItem\(title:|NSMenu\(title:|\badd\(|\b(?:requirement|row|note|choice|paragraph|action)\(')
# A literal right after one of these is a name for the computer, not text for the player. A
# dictionary key or value is written "key":"value" (a ternary's branches have spaces: a : b).
NOT_TEXT = re.compile(r'(?:\bL\(\s*|\b(?:verbatim|systemImage|symbol|systemName|forResource|withExtension|forKey|named|code|id):\s*|[=!]=\s*|\bcase\s+|":)$')
# A lowercase word assigned to a variable is a state's name ("report"), never text.
STATE = re.compile(r'^[a-z][a-z0-9_-]*$')
UNITS = {'ms', 'Hz', 'GB', 'MB', 'FPS'}
# Literals that read like sentences but never reach the screen.
NOT_SCREEN_TEXT = {
    'Overwatch 2 Mac',  # the app's old name, replaced when Recall moves into Applications
    'Light appearance', 'Dark appearance',  # preview builds' developer menu
    # The pipeline helper's log lines, which ShaderRecord turns into support report codes.
    'Prepared and verified', 'Learned pipelines are up to date', 'Current archive covers comparable',
    'Refresh already evaluated', 'no verified improvement', 'to preserve disk headroom',
    'leave no room to save', 'Archive not saved', 'No learned pipelines yet',
    'Pipeline preparation skipped', 'ran out of time',
}
# Text in Hangul or Han is shown as written (the Korean notice, 국服-style names).
OWN_SCRIPT = re.compile(r'[\u1100-\u11ff\u3130-\u318f\uac00-\ud7af\u4e00-\u9fff]')
# A path ("Contents/Helpers/…", "/Library/…"), not a sentence.
PATH = re.compile(r'^/|\S/\S')


def code_lines(path):
    """The file's lines, comment lines blank (doc comments quote L("…") too)."""
    return ['' if line.strip().startswith('//') else line for line in path.read_text().split('\n')]


def without_interpolation(text):
    """A Swift literal's text with each \\( … ) removed, nested parentheses included."""
    out, i = [], 0
    while i < len(text):
        if text.startswith('\\(', i):
            depth, i = 1, i + 2
            while i < len(text) and depth:
                depth += {'(': 1, ')': -1}.get(text[i], 0)
                i += 1
        else:
            out.append(text[i])
            i += 1
    return ''.join(out)


def decode(text):
    """A Swift literal's value: escapes \\n, \\t, \\0, \\", \\\\, \\' and \\u{…}."""
    out, i = [], 0
    while i < len(text):
        if text[i] == '\\':
            if text[i + 1] == 'u':
                end = text.index('}', i)
                out.append(chr(int(text[i + 3:end], 16)))
                i = end + 1
                continue
            out.append({'n': '\n', 't': '\t', '0': '\0', '"': '"', '\\': '\\', "'": "'"}[text[i + 1]])
            i += 2
        else:
            out.append(text[i])
            i += 1
    return ''.join(out)


def keys():
    """Every L("…") key in the app, with where it first appears."""
    found = {}
    for path in SOURCES:
        for number, line in enumerate(code_lines(path), 1):
            for match in re.finditer(r'\bL\(\s*' + LITERAL.pattern, line):
                text = match.group(1)
                if '\\(' in text:
                    raise AssertionError(f'{path.name}:{number}: L() takes fixed text, with values as {{0}}: {text}')
                found.setdefault(decode(text), f'{path.name}:{number}')
    return found


def in_L_values(prefix):
    """True when the text before a literal ends inside an L( … ) call, past its key: a value."""
    start = prefix.rfind('L("')
    if start < 0:
        return False
    rest = prefix[start + 2:]
    key = LITERAL.match(rest)
    return bool(key) and rest[key.end():].lstrip().startswith(',') and rest.count('(') >= rest.count(')')


def values(text):
    return sorted(set(re.findall(r'\{\d+\}', text)))


class Translations(unittest.TestCase):
    def setUp(self):
        self.keys = keys()
        self.assertTrue(LANGUAGES, 'no translations in app/Resources/Localizations')

    def test_every_string_is_translated_with_the_same_values(self):
        for language in LANGUAGES:
            table = json.loads(language.read_text())['Localizable']
            missing = {k: where for k, where in self.keys.items() if k not in table}
            self.assertEqual(missing, {}, f'{language.name} lacks these (key: first use)')
            for key, translation in table.items():
                self.assertTrue(translation.strip(), f'{language.name}: empty translation of {key!r}')
                self.assertEqual(values(translation), values(key), f'{language.name}: {{n}} differ for {key!r}')

    def test_no_translation_is_left_over(self):
        for language in LANGUAGES:
            table = json.loads(language.read_text())['Localizable']
            self.assertEqual(sorted(set(table) - set(self.keys)), [], f'{language.name} translates text the app no longer has')

    def test_info_plist_strings_match_the_build(self):
        for language in LANGUAGES:
            info = json.loads(language.read_text())['InfoPlist']
            self.assertEqual(sorted(info), sorted(build_native_app.INFO_STRINGS.values()), language.name)

    def test_build_writes_readable_strings_files(self):
        with tempfile.TemporaryDirectory() as folder:
            resources = Path(folder)
            languages = build_native_app.localize(resources)
            self.assertEqual(languages, ['en', *[p.stem for p in LANGUAGES]])
            self.assertEqual(plistlib.loads((resources/'en.lproj/Localizable.strings').read_bytes()), {})
            for language in LANGUAGES:
                table = json.loads(language.read_text())
                strings = plistlib.loads((resources/f'{language.stem}.lproj/Localizable.strings').read_bytes())
                self.assertEqual(strings, table['Localizable'])
                info = plistlib.loads((resources/f'{language.stem}.lproj/InfoPlist.strings').read_bytes())
                self.assertEqual(set(info), set(build_native_app.INFO_STRINGS))

    def test_no_on_screen_text_skips_L(self):
        unwrapped = []
        for path in SOURCES:
            for number, line in enumerate(code_lines(path), 1):
                if not ON_SCREEN.search(line):
                    continue
                for match in LITERAL.finditer(line):
                    words = re.findall(r'[A-Za-z]{2,}', without_interpolation(match.group(1)))
                    before, after = line[:match.start()], line[match.end():]
                    if not words or set(words) <= UNITS or NOT_TEXT.search(before) or after.startswith(':') or in_L_values(before):
                        continue
                    if STATE.match(match.group(1)) and re.search(r'(?<![=!<>])=\s*$', before):
                        continue
                    unwrapped.append(f'{path.name}:{number}: {match.group(1)[:80]}')
        self.assertEqual(unwrapped, [], 'on-screen text without L(); use Text(verbatim:) for names and codes')

    def test_no_sentence_skips_L(self):
        """Wider than the on-screen check: any literal of two or more words anywhere (help topics,
        lists, text built from parts) is in L(), unless it is a path, code (escaped straight quotes;
        Recall's copy uses curly ones), text in its own script or listed in NOT_SCREEN_TEXT."""
        unwrapped = []
        for path in SOURCES:
            for number, line in enumerate(code_lines(path), 1):
                for match in LITERAL.finditer(line):
                    raw = match.group(1)
                    text = without_interpolation(raw)
                    if len(re.findall(r'[A-Za-z]{2,}', text)) < 2 or ' ' not in text.strip():
                        continue
                    before, after = line[:match.start()], line[match.end():]
                    if NOT_TEXT.search(before) or after.startswith(':') or in_L_values(before):
                        continue
                    if decode(text) in NOT_SCREEN_TEXT or OWN_SCRIPT.search(text) or PATH.search(text) or '\\"' in raw:
                        continue
                    unwrapped.append(f'{path.name}:{number}: {raw[:80]}')
        self.assertEqual(unwrapped, [], 'sentences without L(); add them to NOT_SCREEN_TEXT only if they never reach the screen')

    @unittest.skipUnless(Path('/usr/bin/swiftc').exists(), 'needs swiftc')
    def test_bold_survives_translation(self):
        """Help shows its text as Markdown. Each translation of text with **bold** must have as
        many bold runs as the English, parsed the way the app parses them: CommonMark won't close
        ** between punctuation and a letter, which a Chinese sentence makes easy to hit."""
        program = (
            'import Foundation\n'
            'func bold(_ text:String)->Int {\n'
            # Values are names and numbers, so a letter stands in for each {n}.
            '    let s=text.replacingOccurrences(of:"\\\\{[0-9]+\\\\}",with:"X",options:.regularExpression)\n'
            '    guard let a=try? AttributedString(markdown:s,options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace)) else { return -1 }\n'
            '    if String(a.characters).contains("**") { return -1 }\n'
            '    return a.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }.count\n'
            '}\n'
            'let data=try! Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))\n'
            'let table=(try! JSONSerialization.jsonObject(with:data) as! [String:Any])["Localizable"] as! [String:String]\n'
            'for (key,value) in table where key.contains("**") { if bold(key) != bold(value) || bold(key) < 1 { print(key) } }\n')
        with tempfile.TemporaryDirectory() as folder:
            source, tool = Path(folder)/'bold.swift', Path(folder)/'bold'
            source.write_text(program)
            subprocess.run(['/usr/bin/swiftc', str(source), '-o', str(tool)], check=True, capture_output=True)
            for language in LANGUAGES:
                wrong = subprocess.run([str(tool), str(language)], check=True, capture_output=True, text=True).stdout.split('\n')
                self.assertEqual([k for k in wrong if k], [], f'{language.name}: bold differs from the English')


if __name__ == '__main__':
    unittest.main()
