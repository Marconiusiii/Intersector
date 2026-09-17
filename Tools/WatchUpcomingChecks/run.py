#!/usr/bin/env python3
"""Check Watch acquisition and phone/Watch Manhattan wording using production code.
No device, location permission, network, or UI access is used.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'IntersectorWatch/WatchOrientationService.swift').read_text()
provider = source[source.index('@MainActor\nfinal class WatchLocationProvider'):source.index('\nstruct WatchMapDataClient')]
context = source[source.index('struct WatchDeviceContext {'):source.index('\nstruct WatchIntersectionCandidate')]
doubles = (Path(__file__).parent / 'Checks.swift').read_text()
wording_checks = (Path(__file__).parent / 'ManhattanChecks.swift').read_text()
phone = (root / 'crossStreet/OrientSvc.swift').read_text()

def direction_functions(text):
    start = text.index('\tstatic func normalizedDegrees(')
    end = text.index('\n\tstatic func spokenDistance', start)
    return text[start:end]

# Compile the actual production functions; preference doubles supply only the
# setting read by these functions. Sensor acquisition is tested separately below.
wording = ('struct AppPrefs { var manhattanSnobMode = false }\n'
           'struct WatchAppPrefs { var manhattanSnobMode = false }\n'
           'enum Geo {\n' + direction_functions(phone) + '\n}\n'
           'enum WatchGeo {\n' + direction_functions(source) + '\n}\n')
with tempfile.TemporaryDirectory(prefix='intersector-watch-checks-') as directory:
    directory = Path(directory)
    combined = directory / 'Checks.swift'
    combined.write_text(doubles + '\n' + context + '\n' + provider + '\n' + wording + wording_checks)
    executable = directory / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-cache-path', str(directory / 'modules'), str(combined), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=35)
