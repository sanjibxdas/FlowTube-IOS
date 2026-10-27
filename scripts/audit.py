#!/usr/bin/env python3
"""Static audit for the Flow iOS port. Catches the classes of mistake an
LLM makes when writing UIKit code for iOS 12 without a compiler."""
import os, re, sys, json

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Flow")

FORBIDDEN = [
    (r"\bimport SwiftUI\b", "SwiftUI is iOS 13+ and forbidden"),
    (r"@main\b", "@main lifecycle is forbidden (AppDelegate only)"),
    (r"\bUIWindowScene\b|\bSceneDelegate\b|application\(_ application: UIApplication, configurationForConnecting", "UIScene is iOS 13+"),
    (r"\basync\s+(func|let)\b|\bawait\s|\bTask\s*\{|\bTask\.detached|\bActor\b", "Swift concurrency requires iOS 13+"),
    (r"\bimport Combine\b|@Published|AnyCancellable|\bPassthroughSubject\b", "Combine requires iOS 13+"),
    (r"UICollectionViewCompositionalLayout|NSCollectionLayoutSection", "Compositional layout is iOS 13+"),
    (r"UICollectionViewDiffableDataSource|UITableViewDiffableDataSource|NSDiffableDataSourceSnapshot", "Diffable data source is iOS 13+"),
    (r"\bUIMenu\b|\bUIAction\b|UIContextMenuInteraction|UIContextMenuConfiguration", "UIMenu / context menu is iOS 13+"),
    (r"UINavigationBarAppearance|UITabBarAppearance|UIBarButtonItem\.appearance\(\)", "Appearance API is iOS 13+"),
    (r"UIColor\(dynamicProvider", "Dynamic colours are iOS 13+"),
    (r"UIColor\.(systemBackground|secondarySystemBackground|tertiarySystemBackground|label|secondaryLabel|tertiaryLabel|systemBlue|systemGray\d?|separator|systemGroupedBackground)\b", "Semantic colours are iOS 13+"),
    (r"UIImage\(systemName:", "SF Symbols require iOS 13+"),
    (r"\.systemMaterial|\.systemThinMaterial|\.systemUltraThinMaterial|\.systemChromeMaterial", "Material blur styles are iOS 13+"),
    (r"UISheetPresentationController|\.sheetPresentationController", "Sheet presentation is iOS 15+"),
    (r"PHPickerViewController", "PHPicker is iOS 14+"),
    (r"UISearchController\(\)\.searchBar\.searchTextField", "searchTextField is iOS 13+"),
    (r"\.insetGrouped\b", "UITableView.Style.insetGrouped is iOS 13+"),
    (r"UIListContentConfiguration|UIListContentTextProperties", "UIListContentConfiguration is iOS 14+"),
    (r"AVPlayerViewController\.\(?allowsPictureInPicturePlayback", "AVPlayerViewController PiP is iOS 14+"),
    (r"UNNotificationPresentationOptions\.banner|\bUNNotificationPresentationOptions\(\[\.banner", ".banner is iOS 14+"),
    (r"@available\(iOS 13|@available\(iOS 14|@available\(iOS 15|if #available\(iOS 1[3-9]", "Guarded newer-API usage: must not be required for core functionality"),
]

PLACEHOLDER = [
    (r"//\s*TODO", "TODO comment"),
    (r"fatalError\(\"not implemented", "unimplemented stub"),
    (r"//\s*FIXME", "FIXME comment"),
    (r"preconditionFailure\(\"TODO", "TODO precondition"),
]

def swift_files():
    out = []
    for base, _, files in os.walk(SRC):
        for f in files:
            if f.endswith(".swift"):
                out.append(os.path.join(base, f))
    return sorted(out)

def strip_strings_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    text = re.sub(r"\"(?:[^\"\\]|\\.)*\"", "\"\"", text)
    return text

def check_balance(text, path, problems):
    pairs = {"{": "}", "(": ")", "[": "]"}
    stack = []
    for i, ch in enumerate(text):
        if ch in pairs:
            stack.append((ch, i))
        elif ch in pairs.values():
            if not stack:
                problems.append((path, "unbalanced closing %r at offset %d" % (ch, i)))
                return
            op, _ = stack.pop()
            if pairs[op] != ch:
                problems.append((path, "mismatched %r / %r at offset %d" % (op, ch, i)))
                return
    if stack:
        problems.append((path, "unclosed %r at offset %d" % stack[-1]))

def main():
    verbose = "--verbose" in sys.argv
    files = swift_files()
    problems = []
    declared = set()
    used = set()
    for path in files:
        raw = open(path, encoding="utf-8", errors="replace").read()
        if not raw.strip():
            problems.append((path, "empty file"))
            continue
        body = strip_strings_comments(raw)
        for pat, why in FORBIDDEN + PLACEHOLDER:
            for m in re.finditer(pat, raw if why in ("TODO comment", "FIXME comment") else body):
                line = body[: m.start()].count("\n") + 1
                problems.append((path, "%s (line %d)" % (why, line)))
        # Brace balance is not checked here: multi-line strings defeat a regex
        # stripper and produce false positives. `swiftc -parse` is the authority.
        for m in re.finditer(r"\b(?:final\s+)?(?:public\s+|internal\s+|private\s+|fileprivate\s+)?(?:class|struct|enum|protocol|extension)\s+([A-Za-z_][A-Za-z0-9_]*)", body):
            declared.add(m.group(1))
        for m in re.finditer(r"\b([A-Z][A-Za-z0-9_]{2,})\b", body):
            used.add(m.group(1))

    # dedupe problems
    seen = set()
    uniq = []
    for p, msg in problems:
        key = (p, msg.split(" (line")[0])
        if key in seen:
            continue
        seen.add(key)
        uniq.append((p, msg))

    print("swift files: %d" % len(files))
    print("declared types: %d" % len(declared))
    if uniq:
        print("problems: %d" % len(uniq))
        for p, msg in uniq[:120]:
            print("  %s: %s" % (os.path.relpath(p, ROOT), msg))
    else:
        print("problems: 0")
    if verbose:
        print(json.dumps(sorted(os.path.relpath(f, ROOT) for f in files), indent=1))
    return 0 if not uniq else 1

if __name__ == "__main__":
    sys.exit(main())
