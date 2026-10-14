#!/usr/bin/env python3
"""Compile the production Watch map service and shared deadline; inject all network responses."""
from pathlib import Path
import subprocess
import tempfile
import sys
root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='intersector-watch-map-') as directory:
    executable = Path(directory) / 'checks'
    source = (root / 'IntersectorWatch/WatchOrientationService.swift').read_text()
    start = source.index('@MainActor\nfinal class WatchLocationProvider')
    end = source.index('\nstruct WatchMapDataClient', start)
    # Hardware acquisition is covered by run.py; fail if a map check touches sensors.
    stub = """@MainActor final class WatchLocationProvider {
        func currentContext(requiresFreshHeading: Bool) async throws -> WatchDeviceContext { fatalError("Unexpected sensor access") }
        func currentHeading(allowCached: Bool) async throws -> CLLocationDirection { fatalError("Unexpected sensor access") }
    }
    """
    service = Path(directory) / 'WatchService.swift'
    service.write_text(source[:start] + stub + source[end:])
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-default-isolation', 'MainActor',
        '-parse-as-library', '-module-cache-path', str(Path(directory) / 'modules'),
        str(root / 'crossStreet/Localization.swift'),
        str(root / 'crossStreet/LookupAttempt.swift'),
        str(root / 'crossStreet/OverpassRequestPolicy.swift'),
        str(service),
        str(Path(__file__).parent / 'MapChecks.swift'), '-o', str(executable)], check=True)
    subprocess.run([str(executable), *sys.argv[1:]], check=True, timeout=60)
