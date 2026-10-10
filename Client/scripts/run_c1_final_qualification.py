#!/usr/bin/env python3
"""Two full native suites on immutable C1 source; no diagnostic campaign."""
import collections
import importlib.util
import json
import os
import pathlib
import re
import subprocess
import sys
import tarfile

SOURCE = '2149b93b76221d311a2bc93ca724b13b50714daf'

def main():
    repo = pathlib.Path.cwd()
    out = pathlib.Path(os.environ['C1_EVIDENCE_ROOT'])
    root = out / 'sources' / 'N1'
    root.mkdir(parents=True)
    archive = out / 'sources' / 'candidate.tar'
    with archive.open('wb') as stream:
        subprocess.run(['git', 'archive', SOURCE, 'Client'], stdout=stream, check=True)
    with tarfile.open(archive) as stream:
        stream.extractall(root, filter='data')
    spec = importlib.util.spec_from_file_location('qualified_driver', root / 'Client/scripts/run_c1_heap_classification.py')
    d = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(d)
    for path, expected in d.CANDIDATE_RAW.items():
        if d.digest((root / path).read_bytes()) != expected:
            raise RuntimeError('Immutable candidate byte mismatch: ' + path)
    manifest = d.manifest(root)
    d.save(out / 'sources/N1-source-manifest.json', {
        'canonicalHead': d.CANONICAL_SHA, 'testedPublicSha': SOURCE,
        'workflowPublicSha': os.environ['GITHUB_SHA'], 'production': manifest})
    import shutil
    shutil.copytree(repo / 'Client/ThirdPartyBuild', root / 'Client/ThirdPartyBuild', symlinks=True)
    udid = os.environ['C1_SIMULATOR_UDID']
    derived = out / 'derived/N1-unsanitized'
    build = out / 'entry/final-build.log'
    args = ['xcodebuild', 'build-for-testing', '-project', 'Client/iPadZeroLagDisplay/iPadCasting.xcodeproj',
            '-scheme', 'iPadCasting', '-destination', 'platform=iOS Simulator,id=' + udid + ',arch=x86_64',
            '-derivedDataPath', str(derived), '-parallel-testing-enabled', 'NO',
            'ARCHS=x86_64', 'ONLY_ACTIVE_ARCH=YES', 'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO',
            'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG C1_LIFETIME_DIAGNOSTICS C1_CANDIDATE_SEMANTICS']
    if d.command(args, root, build):
        raise RuntimeError('Qualification build failed')
    runs = list(derived.glob('Build/Products/*.xctestrun'))
    if len(runs) != 1:
        raise RuntimeError('Expected one xctestrun')
    run = runs[0]
    d.patch_environment(run, {'C1_DIAGNOSTIC_MODE': 'unsanitized'})
    enum = out / 'entry/test-inventory.json'
    args = ['xcodebuild', 'test-without-building', '-xctestrun', str(run), '-destination',
            'platform=iOS Simulator,id=' + udid + ',arch=x86_64', '-parallel-testing-enabled', 'NO',
            '-enumerate-tests', '-test-enumeration-style', 'flat', '-test-enumeration-format', 'json',
            '-test-enumeration-output-path', str(enum)]
    if d.command(args, root, out / 'entry/enumeration.log'):
        raise RuntimeError('Inventory enumeration failed')
    document = json.loads(enum.read_text())
    expected = set()
    def visit(value):
        if isinstance(value, str):
            match = re.fullmatch(r'iPadCastingTests/([^/]+)/([^/]+)', value)
            if match:
                expected.add(match[1] + '/' + match[2].removesuffix('()'))
        elif isinstance(value, dict):
            for child in value.values(): visit(child)
        elif isinstance(value, list):
            for child in value: visit(child)
    visit(document)
    if not expected:
        raise RuntimeError('Cannot derive complete enumerated inventory; no tests dispatched')
    d.save(out / 'entry/expected-inventory.json', sorted(expected))
    results = []
    for number in (1, 2):
        point = out / 'full' / str(number)
        result = d.run_test(root, point, derived, run, udid, [], 1, 'unsanitized')
        text = (point / 'xcodebuild.stdout-stderr.log').read_text(errors='replace')
        passed = re.findall(r"Test Case '-\[(?:iPadCastingTests\.)?([^ ]+) ([^]]+)\]' passed", text)
        counts = collections.Counter(cls + '/' + method for cls, method in passed)
        result['expectedInventory'] = sorted(expected)
        result['actualInventory'] = sorted(counts)
        result['inventoryExact'] = set(counts) == expected and all(n == 1 for n in counts.values())
        result['processRestarts'] = len(re.findall('Restarting after unexpected exit', text))
        summary_text = (point / 'xcresult-summary.json.log').read_text(errors='replace')
        summary = json.loads(summary_text[summary_text.index('{'):])
        result['xcresultPassed'] = summary['passedTests']
        result['xcresultFailed'] = summary['failedTests']
        result['clean'] = (result['clean'] and result['inventoryExact'] and result['processRestarts'] == 0
                           and summary['failedTests'] == 0 and summary['passedTests'] == len(expected))
        d.save(point / 'point.json', result)
        results.append(result)
        d.save(out / 'classification.json', {'testedPublicSha': SOURCE, 'fullNative': results,
               'C1_COMMITTED': False, 'C1_GREEN': False, 'IPA_CREATED': False, 'HOST_PACKAGE_CREATED': False})
        print(json.dumps(result), flush=True)
        if not result['clean']:
            return 1
    return 0

if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        root = pathlib.Path(os.environ['C1_EVIDENCE_ROOT'])
        (root / 'STOP.json').write_text(json.dumps({'error': str(error), 'C1_GREEN': False}))
        raise
