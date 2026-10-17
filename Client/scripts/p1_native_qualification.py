import collections,hashlib,importlib.util,json,os,pathlib,re,subprocess,sys,tarfile,zipfile
root=pathlib.Path.cwd(); out=root/'evidence'
def run(args,log):
 with (out/log).open('w') as f:
  p=subprocess.run(args,stdout=f,stderr=subprocess.STDOUT)
 if p.returncode: raise RuntimeError(str(args)+' exit='+str(p.returncode))
def sha(b):return hashlib.sha256(b).hexdigest()
if sys.argv[1]=='prepare':
 spec=importlib.util.spec_from_file_location('attest',root/'Client/scripts/verify_g02_native_consumer_attestation.py')
 v=importlib.util.module_from_spec(spec);spec.loader.exec_module(v)
 a=json.loads((out/'producer/artifact.json').read_text()); r=json.loads((out/'producer/run.json').read_text())
 v.verify_metadata(a,r); evidence=v.read_evidence_zip(out/'producer/artifact.zip',a); verified=v.verify_evidence(evidence)
 with tarfile.open(fileobj=__import__('io').BytesIO(evidence['G02-native-deps-openssl-3.5.7.tar.gz']),mode='r:gz') as t:
  t.extractall(root,filter='data')
 (out/'dependency-verification.json').write_text(json.dumps(verified,indent=2))
 run(['xcodebuild','-version'],'toolchain.log')
 assert 'Xcode 16.4' in (out/'toolchain.log').read_text()
 assert subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-version'],text=True).strip()=='18.5'
 files={str(p):sha(p.read_bytes()) for p in (root/'Client').rglob('*') if p.is_file() and 'ThirdPartyBuild' not in p.parts}
 (out/'source-manifest.json').write_text(json.dumps({'publicSha':os.environ['GITHUB_SHA'],'files':files},indent=2))
else:
 devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','-j']))['devices']
 choices=[d for runtime,ds in devices.items() if runtime.endswith('iOS-18-5') for d in ds if 'iPad' in d['name']]
 assert choices,'No iOS 18.5 iPad simulator'
 udid=choices[0]['udid'];subprocess.run(['xcrun','simctl','boot',udid],capture_output=True)
 run(['xcrun','simctl','bootstatus',udid,'-b'],'boot.log')
 base=['xcodebuild','-project','Client/iPadZeroLagDisplay/iPadCasting.xcodeproj','-scheme','iPadCasting',
  '-destination','platform=iOS Simulator,id='+udid+',arch=x86_64','-derivedDataPath',str(out/'derived'),
  '-parallel-testing-enabled','NO','ARCHS=x86_64','ONLY_ACTIVE_ARCH=YES','CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO']
 run(base+['build-for-testing'],'build.log')
 selectors=[x for x in os.environ.get('P1_SELECTORS','').split(',') if x]
 run(base+['test-without-building','-enumerate-tests','-test-enumeration-style','flat',
  '-test-enumeration-format','json','-test-enumeration-output-path',str(out/'inventory.json')],'enumerate.log')
 expected=set()
 def visit(x):
  if isinstance(x,str) and re.fullmatch(r'iPadCastingTests/[^/]+/[^/]+',x): expected.add(x.removeprefix('iPadCastingTests/').removesuffix('()'))
  elif isinstance(x,dict):
   for y in x.values():visit(y)
  elif isinstance(x,list):
   for y in x:visit(y)
 visit(json.loads((out/'inventory.json').read_text()));assert expected
 if selectors: expected={x for x in expected if any(('iPadCastingTests/'+x)==s or ('iPadCastingTests/'+x).startswith(s+'/') for s in selectors)}
 assert expected
 result=out/'result.xcresult'
 args=base+['test-without-building','-resultBundlePath',str(result)]+['-only-testing:'+s for s in selectors]
 p=subprocess.run(args,stdout=(out/'test.log').open('w'),stderr=subprocess.STDOUT)
 run(['xcrun','xcresulttool','get','test-results','tests','--path',str(result)],'tests.json')
 run(['xcrun','xcresulttool','get','test-results','summary','--path',str(result)],'summary.json')
 counts=collections.Counter();statuses={}
 def tests(x):
  if isinstance(x,dict):
   if str(x.get('nodeType','')).replace(' ','').lower()=='testcase':
    key=x['nodeIdentifier'].removeprefix('iPadCastingTests/').removesuffix('()');counts[key]+=1;statuses[key]=x.get('result')
   for y in x.values():tests(y)
  elif isinstance(x,list):
   for y in x:tests(y)
 tests(json.loads((out/'tests.json').read_text()));summary=json.loads((out/'summary.json').read_text())
 text=(out/'test.log').read_text(errors='replace')
 findings=re.findall(r'Restarting after unexpected exit|AddressSanitizer|runtime error:|malloc: \*\*\*|EXC_BAD_ACCESS',text)
 verdict={'exit':p.returncode,'expected':sorted(expected),'actual':dict(counts),'statuses':statuses,'summary':summary,'runtimeFindings':findings}
 (out/'verdict.json').write_text(json.dumps(verdict,indent=2))
 assert p.returncode==0 and set(counts)==expected and all(n==1 for n in counts.values())
 assert all(s=='Passed' for s in statuses.values()) and summary['failedTests']==0 and summary['skippedTests']==0 and not findings
