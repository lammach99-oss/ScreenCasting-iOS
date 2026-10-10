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

SOURCE = os.environ.get('GITHUB_SHA', '')

def xcresult_inventory(document):
    counts = collections.Counter()
    statuses = {}
    def visit(node):
        if isinstance(node, dict):
            if str(node.get('nodeType', '')).replace(' ', '').lower() == 'testcase':
                identifier = node.get('nodeIdentifier', '')
                match = re.fullmatch(r'(?:iPadCastingTests/)?([^/]+)/([^/]+)', identifier)
                if not match:
                    raise RuntimeError('Unrecognized xcresult test identifier: ' + identifier)
                key = match[1] + '/' + match[2].removesuffix('()')
                counts[key] += 1
                statuses[key] = node.get('result')
            for child in node.values(): visit(child)
        elif isinstance(node, list):
            for child in node: visit(child)
    visit(document)
    if not counts:
        raise RuntimeError('Authoritative xcresult inventory is empty')
    return counts, statuses

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
    if not re.fullmatch(r'[0-9a-f]{40}', SOURCE):
        raise RuntimeError('Exact immutable source SHA required')
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
    selectors = [s.strip() for s in os.environ.get('C1_QUALIFICATION_SELECTORS', '').split(',') if s.strip()]
    selected = expected
    if selectors:
        selected = {key for key in expected if any(
            ('iPadCastingTests/' + key) == selector or
            ('iPadCastingTests/' + key).startswith(selector + '/') for selector in selectors)}
        if not selected:
            raise RuntimeError('No enumerated tests match the focused selectors')
    results = []
    for number in ((1,) if selectors else (1, 2)):
        point = out / 'full' / str(number)
        result = d.run_test(root, point, derived, run, udid, selectors, 1, 'unsanitized')
        text = (point / 'xcodebuild.stdout-stderr.log').read_text(errors='replace')
        inventory_log = point / 'xcresult-tests.json.log'
        if d.command(['xcrun', 'xcresulttool', 'get', 'test-results', 'tests', '--path',
                      str(point / 'result.xcresult')], root, inventory_log):
            raise RuntimeError('Authoritative xcresult inventory export failed')
        inventory_text = inventory_log.read_text()
        counts, statuses = xcresult_inventory(json.loads(inventory_text[inventory_text.index('{'):]))
        result['expectedInventory'] = sorted(selected)
        result['actualInventory'] = sorted(counts)
        result['inventoryExact'] = set(counts) == selected and all(n == 1 for n in counts.values())
        result['testStatuses'] = statuses
        result['processRestarts'] = len(re.findall('Restarting after unexpected exit', text))
        summary_text = (point / 'xcresult-summary.json.log').read_text(errors='replace')
        summary = json.loads(summary_text[summary_text.index('{'):])
        result['xcresultPassed'] = summary['passedTests']
        result['xcresultFailed'] = summary['failedTests']
        result['clean'] = (result['clean'] and result['inventoryExact'] and result['processRestarts'] == 0
                           and summary['failedTests'] == 0 and summary['skippedTests'] == 0
                           and summary['passedTests'] == len(selected)
                           and all(status == 'Passed' for status in statuses.values()))
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
