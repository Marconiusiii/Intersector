#!/usr/bin/env python3
"""Check bundled translation coverage and placeholder compatibility."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LANGUAGES = ('en', 'es', 'pt-BR')
errors = []

def units(value):
    if 'stringUnit' in value:
        yield value['stringUnit']
    for group in value.get('variations', {}).values():
        for variant in group.values():
            yield from units(variant)

def placeholders(value):
    # Positional arguments may move, but their types and count must be preserved.
    return sorted(re.findall(r'%(?:\d+\$)?(?:\.\d+)?(lld|ld|@|d|f)', value))

catalogs = {}
for path in sorted((ROOT / 'crossStreet').glob('*.xcstrings')):
    catalog = json.loads(path.read_text())
    catalogs[path.stem] = catalog['strings']
    for key, entry in catalog['strings'].items():
        if entry.get('shouldTranslate') is False:
            continue
        locales = entry.get('localizations', {})
        for language in LANGUAGES:
            values = list(units(locales.get(language, {})))
            if not values:
                errors.append(f'{path.name}: {key}: missing {language}')
            for unit in values:
                if unit.get('state') != 'translated' or not unit.get('value'):
                    errors.append(f'{path.name}: {key}: incomplete {language}')
                if placeholders(unit.get('value', '')) != placeholders(key):
                    errors.append(f'{path.name}: {key}: placeholders differ in {language}')
                if '${applicationName}' in key and unit['value'].count('${applicationName}') != 1:
                    errors.append(f'{path.name}: {key}: application name missing in {language}')

keys = catalogs['Localizable']
for folder in ('crossStreet', 'IntersectorWatch'):
    for path in (ROOT / folder).glob('*.swift'):
        for match in re.finditer(r'L10n\.(?:text|quantity|decimalQuantity)\("((?:\\.|[^"\\])*)"', path.read_text()):
            key = json.loads('"' + match[1] + '"')
            if key not in keys:
                errors.append(f'{path.name}: missing catalog key {key}')

# App Intents metadata and invocation phrases use Apple's native localization APIs.
for path in [ROOT / 'crossStreet/CrossStreetIntents.swift', ROOT / 'IntersectorWatch/WatchIntents.swift']:
    source = path.read_text()
    for match in re.finditer(r'"([^"\n]*\\\(.applicationName\)[^"\n]*)"', source):
        key = match[1].replace(r"\(.applicationName)", "${applicationName}")
        if key not in catalogs['AppShortcuts']:
            errors.append(f'{path.name}: missing Siri phrase {key}')
    for line in source.splitlines():
        if any(marker in line for marker in ('LocalizedStringResource =', 'IntentDescription(', '@Property(title:', 'TypeDisplayRepresentation(name:', 'shortTitle:')):
            for key in re.findall(r'"([^"\n]+)"', line):
                if key not in keys:
                    errors.append(f'{path.name}: missing intent metadata {key}')

if errors:
    raise SystemExit('\n'.join(errors))
print(f'Passed: {sum(map(len, catalogs.values()))} entries across {len(catalogs)} catalogs; '
      'English, Spanish and Brazilian Portuguese complete; placeholders and source references match.')
