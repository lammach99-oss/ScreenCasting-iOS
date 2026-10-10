#!/usr/bin/env python3
"""Test-only matched C1 lifetime campaign. Never publishes or packages anything."""
import hashlib, json, os, pathlib, plistlib, re, shutil, signal, subprocess, sys, tarfile, time
CANDIDATE_SHA='509c54fbb0f5d48bdf59cab71dea90667cbc9e30'
CANONICAL_SHA='a48980f5417dff77785d882eea0909f8fc51c5ad'
CANDIDATE_RAW={
 'Client/iPadZeroLagDisplay/AudioManager.swift':'6a2b2383eaca689eed1e7e5bded06aa6e8804bb3ae0bf41dfedfe045afc6a9c8',
 'Client/iPadZeroLagDisplay/NetworkManager.swift':'924715b9eca00a377cbaa83c5b8a1bd800826bbaad50f70e261de4b143ff3e05',
 'Client/iPadZeroLagDisplayTests/WireProtocolTests.swift':'9721f1914eed5336f5798f340c4566f8d7c2e8a17a121187b60af3adfb8d51d3'}
BASELINE_RAW={
 'Client/iPadZeroLagDisplay/AudioManager.swift':'e896047b1496b2f4013817744a8fc4b9cf676a9f3bcf49a700a766bf3b5fc359',
 'Client/iPadZeroLagDisplay/NetworkManager.swift':'231871cde24acda5d02b2d0e8e36bd88168b6c5dee73b50d6fac4c29e50e4924'}
EXPECTED_PRODUCTION={'Client/iPadZeroLagDisplay/AccessUnitMailbox.swift': '15854cda3a0cd9853e4ef0eb85d560b96e19b10ac522aaffb02dd8d11beb70b0', 'Client/iPadZeroLagDisplay/AudioManager.swift': 'e896047b1496b2f4013817744a8fc4b9cf676a9f3bcf49a700a766bf3b5fc359', 'Client/iPadZeroLagDisplay/ContentView.swift': '8ab88e471beded57341feffea715cc7dd026c228644193c45d8fcefdb9fb613a', 'Client/iPadZeroLagDisplay/DecoderManager.swift': '90b9ff87cdc39521b9c74c55f7b567829151d0f6dc5758f8054e1678f0b7e5c5', 'Client/iPadZeroLagDisplay/DiscoveryManager.swift': '801cc763e873a70f50798f50ed2fb69ee86f1c46888317c720eea51803c5b4e3', 'Client/iPadZeroLagDisplay/H264VideoConfiguration.swift': '313ed1ef0176c8e2ace739f428cb24474318d4f17c3de74ffc5631414e0512b9', 'Client/iPadZeroLagDisplay/Info.plist': 'd3d998da6693593075d92f0edce90ea24c1cda97f229dc916c0c736a15695e1b', 'Client/iPadZeroLagDisplay/InputGeometryDiagnostics.swift': 'c5a0f6ec204713169964d0cde6c02ce131ec69c2e09a40ea60ba1c8e8f3621b0', 'Client/iPadZeroLagDisplay/MetalView.swift': 'ad7dd949e2ecb262a20ce45f973e829c762019e9f1dbe1fa0a59db0e7106860a', 'Client/iPadZeroLagDisplay/NetworkManager.swift': '231871cde24acda5d02b2d0e8e36bd88168b6c5dee73b50d6fac4c29e50e4924', 'Client/iPadZeroLagDisplay/PencilOverlayView.swift': '622ec09122f0d1597f84ccdd37c911077f1a3eafccf045c7b0ab52e51b4e8733', 'Client/iPadZeroLagDisplay/PencilTouchView.swift': '13d05b4fe69dcd398a3b3d61bda11670cf296cf8163d69a3345107491f06630f', 'Client/iPadZeroLagDisplay/RealtimeTransport/AudioJitterBuffer.swift': '993aecd6db2c5821766264420226e745afdc136317315afe4a302f803d0d6f73', 'Client/iPadZeroLagDisplay/RealtimeTransport/ControlChannelWriter.swift': 'a981e3c3338251e9a49007cd7ed4ffbd6c12a17adc26207350ee45ee8519743e', 'Client/iPadZeroLagDisplay/RealtimeTransport/HevcRtpReassembler.swift': '6765517d469ec51d405c2b34bccc3b499a66f3cd49e622b50f56873643a6a420', 'Client/iPadZeroLagDisplay/RealtimeTransport/OpusDecoder.swift': 'bad6dd4d781d1ca838bb3bc8e58e38a403e3a70d3598187a5ac887fa6aee4584', 'Client/iPadZeroLagDisplay/RealtimeTransport/RtpPacket.swift': '541d6e2285bea6fd1c92f2b4a82d81e7c778e5243dc544d1edd7f043086c0c51', 'Client/iPadZeroLagDisplay/RealtimeTransport/SrtpSession.swift': '31299e96ef5b034e8f970a74621e8feb690aa514bb05211b1f6c87397e138fac', 'Client/iPadZeroLagDisplay/RealtimeTransport/TransportNegotiation.swift': '4c19a38d29c7d84de94436b1a702fc0e554b1eb265da6b9e6212fba939bd2895', 'Client/iPadZeroLagDisplay/RealtimeTransport/UsbLaneServer.swift': 'fb87ca3fe21da669e6d3655a3b5cddc412be6648f0038caa865a877a7c75d253', 'Client/iPadZeroLagDisplay/RealtimeTransport/WifiMediaReceiver.swift': 'bccfb3dc86fbd68d88aaec9356f28964cffce350e4c6511c4df6def203770f44', 'Client/iPadZeroLagDisplay/Renderer.swift': 'd240c2c19ab451f3908188aa7c9785a7760eaa0603a0ded50bd7d9276265fd4e', 'Client/iPadZeroLagDisplay/SettingsView.swift': 'cfc9d668c5776342e8f6ba1b801f03558bffbf2dbe465a28da644da6b3d6fef8', 'Client/iPadZeroLagDisplay/Shaders.metal': '743d3db7b8ba7ab1364dc1273207326e145b95c7244103de1c8a908e79166015', 'Client/iPadZeroLagDisplay/StreamManager.swift': '67b0b05f4b881319ef653d2a73359938baf456ecc6f81e1763e89dd278fa564f', 'Client/iPadZeroLagDisplay/TransportTelemetry.swift': '853bea11d4993c6f3bd9f7968a11c6d8a480b236f6b5ba8b7921e5cf490afd1c', 'Client/iPadZeroLagDisplay/USBServerIdentity.swift': '4557847cf629a700ebdbc6b560f330b336b5ddcb577956d4aa380e9bc9dbca10', 'Client/iPadZeroLagDisplay/iPadZeroLagDisplayApp.swift': '53f6c6cb933a83e9fb694134271a41f5fd86860194535d825a46992d893dbafe'}
APPROVED_SIMULATOR_DECODER_RAW='9bee1aaa36711e16e6c9b7cb319e30b36078548cd5c6006640f6e4c6854f6992'
APPROVED_SIMULATOR_DECODER_NORMALIZED='dca09f998e80f791d845cccc4414cd6e39ea7924e66f872436de036d5b692d81'
NEUTRAL=['iPadCastingTests/C1NeutralLifetimeTests','iPadCastingTests/C1NativeAVAudioLifetimeTests','iPadCastingTests/C1DecoderLifecycleInstrumentationTests']
SEMANTIC={
 'S1':['iPadCastingTests/USBListenerLifetimeTests/testLegacyUsbForegroundDropsPreFencePcmAndMatchingPongReleasesFreshPcm'],
 'S2':['iPadCastingTests/C1AlternateSemanticTests/testAlternateForegroundPcmFenceWithExplicitOwners']}
CRASH_PATTERN=re.compile(r'malloc:.*(?:corrupt|free list|not allocated)|ERROR: AddressSanitizer|SUMMARY:.*Sanitizer|AddressSanitizer:DEADLYSIGNAL|Restarting after unexpected exit',re.I)
FAULT_PATTERN=re.compile(r'\[C1_CALLBACK_FAULT\]|WARNING:.*Sanitizer|malloc:.*(?:warning|nano zone abandoned)',re.I)
def findings(text):
 return [line for line in text.splitlines() if CRASH_PATTERN.search(line) or FAULT_PATTERN.search(line)]
def classify(points):
 def clean(name):return points.get(name,{}).get('clean',False)
 def crash(name):return points.get(name,{}).get('crash',False)
 if crash('N0'): return 'BASELINE_RUNTIME'
 if clean('N0') and crash('N1'): return 'C1_PRODUCTION_NATIVE_LIFETIME'
 if clean('N0') and clean('N1'):
  if crash('S1') and clean('S2'): return 'TEST_HARNESS_ORIGINAL_FIXTURE'
  if crash('S1') and crash('S2'): return 'C1_SEMANTIC_PRODUCTION_PATH'
  if clean('S1') and clean('S2'): return 'NON_REPRODUCIBLE'
 return 'UNRESOLVED'
def digest(data):return hashlib.sha256(data).hexdigest()
def save(path,data):
 path.parent.mkdir(parents=True,exist_ok=True)
 path.write_text(json.dumps(data,indent=2)+'\n',encoding='utf-8')
def command(args,directory,log,env=None,timeout=1800):
 log.parent.mkdir(parents=True,exist_ok=True)
 with log.open('wb') as output:
  output.write(('COMMAND: '+json.dumps(args)+'\n').encode());output.flush()
  process=subprocess.Popen(args,cwd=directory,stdout=output,stderr=subprocess.STDOUT,env=env,start_new_session=True)
  try:return process.wait(timeout=timeout)
  except subprocess.TimeoutExpired:
   os.killpg(process.pid,signal.SIGTERM)
   try:process.wait(timeout=30)
   except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.wait()
   output.write(b'\nDIAGNOSTIC_WATCHDOG_EXPIRED; NOT A LATENCY SLA\n');return 124

def manifest(root):
 actual={}
 for relative,expected in EXPECTED_PRODUCTION.items():
  data=(root/relative).read_bytes()
  actual[relative]={'rawSha256':digest(data),'normalizedSha256':digest(data.replace(b'\r\n',b'\n')),'canonicalExpected':expected}
 return actual

def prepare_variant(repo,root,variant,baseline_ref):
 root.parent.mkdir(parents=True,exist_ok=True)
 archive=root.parent/(variant+'.tar')
 with archive.open('wb') as stream:subprocess.run(['git','archive','--format=tar',os.environ['GITHUB_SHA'],'Client'],cwd=repo,stdout=stream,check=True)
 root.mkdir(parents=True,exist_ok=False)
 with tarfile.open(archive) as stream:stream.extractall(root,filter='data')
 for relative in CANDIDATE_RAW:
  if digest((root/relative).read_bytes())!=CANDIDATE_RAW[relative]:raise RuntimeError('C1 raw source drift: '+relative)
 if variant=='N0':
  for relative,expected in BASELINE_RAW.items():
   data=subprocess.check_output(['git','show',baseline_ref+':'+relative],cwd=repo)
   if digest(data)!=expected:raise RuntimeError('Noncanonical baseline bytes: '+relative)
   (root/relative).write_bytes(data)
  # Neutral N0 deliberately does not compile the unrelated C1 semantic tests.
  # Preserve their file bytes; only alter the diagnostic test target Sources entry.
  project=root/'Client/iPadZeroLagDisplay/iPadCasting.xcodeproj/project.pbxproj'
  data=project.read_bytes()
  entry=b'\t\t\t\t300111111111111111111110 /* WireProtocolTests.swift in Sources */,'+(b'\r\n' if b'\r\n' in data else b'\n')
  if data.count(entry)!=1:raise RuntimeError('Unexpected WireProtocolTests Sources entry')
  project.write_bytes(data.replace(entry,b''))
 sources=manifest(root)
 for relative,row in sources.items():
  expected=row['canonicalExpected']
  if variant=='N1' and relative in BASELINE_RAW:
   expected=digest((repo/relative).read_bytes().replace(b'\r\n',b'\n'))
  if relative=='Client/iPadZeroLagDisplay/DecoderManager.swift' and row['rawSha256']==APPROVED_SIMULATOR_DECODER_RAW:
   expected=APPROVED_SIMULATOR_DECODER_NORMALIZED
   row['approvedSimulatorInstrumentationException']=True
  if row['normalizedSha256']!=expected:raise RuntimeError('Frozen production drift: '+relative)
 test_inputs={}
 for file in (root/'Client').rglob('*'):
  if file.is_file() and (file.suffix in {'.swift','.h','.cpp','.c','.metal','.plist'} or file.name=='project.pbxproj'):
   test_inputs[str(file.relative_to(root))]=digest(file.read_bytes())
 save(root.parent/(variant+'-test-input-manifest.json'),test_inputs)
 save(root.parent/(variant+'-source-manifest.json'),{'variant':variant,'canonicalHead':CANONICAL_SHA,'candidateProductionSha':CANDIDATE_SHA,'diagnosticPublicSha':os.environ['GITHUB_SHA'],'baselineObjectRef':baseline_ref,'production':sources,'harnessRawSha256':digest((root/'Client/iPadZeroLagDisplayTests/C1LifetimeDiagnosticsTests.swift').read_bytes()),'N0WireSemanticTestsCompiled':variant!='N0','originalC1SemanticRawSha256':digest((root/'Client/iPadZeroLagDisplayTests/WireProtocolTests.swift').read_bytes())})
 shutil.copytree(repo/'Client/ThirdPartyBuild',root/'Client/ThirdPartyBuild',symlinks=True)
 return root

def patch_environment(path,environment):
 document=plistlib.loads(path.read_bytes()); targets=[]
 for config in document.get('TestConfigurations',[]):targets.extend(config.get('TestTargets',[]))
 if not targets:targets=[v for k,v in document.items() if not k.startswith('__') and isinstance(v,dict) and 'TestBundlePath' in v]
 if not targets:raise RuntimeError('No XCTest targets in xctestrun')
 for target in targets:
  target.setdefault('EnvironmentVariables',{}).update(environment)
  target.setdefault('TestingEnvironmentVariables',{}).update(environment)
 path.write_bytes(plistlib.dumps(document))

def collect(point,derived,udid):
 symbols=point/'symbols';symbols.mkdir(parents=True,exist_ok=True)
 for binary in derived.glob('Build/Products/**/*.dSYM'):
  target=symbols/binary.name
  if not target.exists():shutil.copytree(binary,target,symlinks=True)
 for name in ['iPadCasting','iPadCastingTests','iPadCasting.debug.dylib','iPadCastingTests.debug.dylib']:
  for binary in derived.glob('Build/Products/**/'+name):
   if binary.is_file():shutil.copy2(binary,symbols/(name+'-'+digest(binary.read_bytes())[:12]))
 roots=[pathlib.Path.home()/'Library/Logs/DiagnosticReports',pathlib.Path.home()/'Library/Developer/CoreSimulator/Devices'/udid/'data/Library/Logs']
 crashes=point/'crashes';crashes.mkdir(parents=True,exist_ok=True)
 for root in roots:
  if root.exists():
   for extension in ['*.ips','*.crash']:
    for report in root.rglob(extension):
     try:shutil.copy2(report,crashes/(digest(report.read_bytes())[:16]+'-'+report.name))
     except OSError:pass
 result=point/'result.xcresult'
 if result.exists():
  command(['xcrun','xcresulttool','get','test-results','summary','--path',str(result)],point,point/'xcresult-summary.json.log',timeout=120)
  command(['xcrun','xcresulttool','export','diagnostics','--path',str(result),'--output-path',str(point/'xcresult-diagnostics')],point,point/'xcresult-export.log',timeout=120)
 # Only match app/test frames with their exact retained symbol UUIDs.
 symbol_map={}
 for dwarf in symbols.glob('**/DWARF/*'):
  output=subprocess.run(['xcrun','dwarfdump','--uuid',str(dwarf)],capture_output=True,text=True)
  (symbols/(dwarf.name+'-uuid.txt')).write_text(output.stdout+output.stderr,encoding='utf-8')
  for uuid in re.findall(r'UUID: ([A-Fa-f0-9-]+)',output.stdout):symbol_map[uuid.replace('-','').lower()]=dwarf
 stacks=[]
 for report in crashes.glob('*.ips'):
  try:
   text=report.read_text(encoding='utf-8');decoder=json.JSONDecoder();document,index=decoder.raw_decode(text)
   if 'threads' not in document:document,_=decoder.raw_decode(text[index:].lstrip())
   images=document.get('usedImages',document.get('binaryImages',[]))
   for thread in document.get('threads',[]):
    for frame in thread.get('frames',[]):
     image_index=frame.get('imageIndex')
     if image_index is None or image_index>=len(images):continue
     image=images[image_index]
     if image.get('name') not in ['iPadCasting','iPadCastingTests','iPadCasting.debug.dylib','iPadCastingTests.debug.dylib']:continue
     dwarf=symbol_map.get(str(image.get('uuid','')).replace('-','').lower())
     row={'report':report.name,'image':image,'frame':frame,'symbolicated':False}
     if dwarf is not None:
      base=image.get('base',0);offset=frame.get('imageOffset',0)
      if isinstance(base,str):base=int(base,0)
      if isinstance(offset,str):offset=int(offset,0)
      result=subprocess.run(['xcrun','atos','-arch','x86_64','-o',str(dwarf),'-l',hex(base),hex(base+offset)],capture_output=True,text=True)
      row.update({'atosExit':result.returncode,'atos':result.stdout+result.stderr,'symbolicated':result.returncode==0 and not result.stdout.strip().startswith('0x')})
     stacks.append(row)
  except (OSError,ValueError,KeyError,TypeError) as error:stacks.append({'report':report.name,'decodeError':str(error)})
 save(point/'app-test-callback-stacks.json',stacks)
 # Raw results and matching binaries/dSYMs are retained even if export fails.


def execution_counts(text,selectors,repeats):
 neutral=['testPinnedRuntimeAndDiagnosticEnvironment','test300PcmBuffersCompleteExactlyOnce','testResetPending1_8_20_100CannotMutateReplacement','test100SingletonLegacyReplacementsFenceStaleCallbacks','test100AudioObserverAndEngineResetFixtureLifetimes','testListenerStopSavedAcceptAndCallbackQuiescence','testOrdinaryPingWriterCompletionAndRetiredLateSend']
 methods=[]
 for selector in selectors:
  if selector.endswith('/C1NeutralLifetimeTests'):methods.extend(neutral)
  elif selector.endswith('/C1NativeAVAudioLifetimeTests'):methods.append('test100NativeDataRenderedManualRenderStopResetCycles')
  elif selector.endswith('/C1DecoderLifecycleInstrumentationTests'):methods.append('testSingleCallerAndAsyncCleanupPreserveLifecycleMeasurements')
  else:methods.append(selector.rsplit('/',1)[-1])
 counts={method:len(re.findall(r'Test Case[^\n]*\b'+re.escape(method)+r'\b[^\n]* passed[ (]',text)) for method in methods}
 all_passed=len(re.findall(r'Test Case[^\n]* passed[ (]',text))
 verified=all(value>=repeats for value in counts.values()) if selectors else all_passed>=628
 for selector in selectors:
  if '/C1OrderedSequenceTests/' in selector:
   scenario=selector.rsplit('/',1)[-1].removeprefix('test')
   pair_numbers=[int(x) for x in re.findall(r'\[C1_PAIR_QUALIFIED\] scenario='+re.escape(scenario)+r' repetition=(\d+)',text)]
   verified=verified and pair_numbers==list(range(1,21))
   semantic='S1' if 'S1' in scenario else 'S2'
   expected=['WiFi',semantic] if scenario.startswith('Wifi') else [semantic,'WiFi']
   retired=re.findall(r'\[C1_BODY_RETIRED\] scenario='+re.escape(scenario)+r' repetition=(\d+) body=(\w+) pid=(\d+)',text)
   order=re.findall(r'\[C1_OBSERVED_ORDER\] scenario='+re.escape(scenario)+r' repetition=(\d+) first=(\w+) second=(\w+) pid=(\d+)',text)
   verified=verified and [(int(n),body) for n,body,pid in retired]==[(n,body) for n in range(1,21) for body in expected]
   verified=verified and [(int(n),first,second) for n,first,second,pid in order]==[(n,*expected) for n in range(1,21)]
   verified=verified and len({row[-1] for row in retired+order})==1
 return {'methodPassCounts':counts,'allMethodPasses':all_passed,'verified':verified,'qualificationSource':'XCTest case completion log; if interleaved/incomplete, remain unqualified pending xcresult review'}

def repetition_arguments(repeats):
 if repeats<1:raise ValueError('Positive repetition count required')
 return ['-test-iterations',str(repeats),'-test-repetition-relaunch-enabled','NO'] if repeats>1 else []

def run_test(root,point,derived,xctestrun,udid,selectors,repeats,mode):
 point.mkdir(parents=True,exist_ok=True)
 args=['xcodebuild','test-without-building','-xctestrun',str(xctestrun),'-destination','platform=iOS Simulator,id='+udid+',arch=x86_64','-parallel-testing-enabled','NO','-resultBundlePath',str(point/'result.xcresult')]
 args+=repetition_arguments(repeats)
 args+=['-only-testing:'+selector for selector in selectors]
 code=command(args,root,point/'xcodebuild.stdout-stderr.log')
 text=(point/'xcodebuild.stdout-stderr.log').read_text(encoding='utf-8',errors='replace')
 observed=findings(text)
 executions=execution_counts(text,selectors,repeats)
 crashed=bool(CRASH_PATTERN.search(text))
 clean=code==0 and executions['verified'] and not observed and (point/'result.xcresult').exists() and '** TEST EXECUTE SUCCEEDED **' in text
 result={'executions':executions,'exit':code,'clean':clean,'crash':crashed,'findings':observed,'requestedRepeats':repeats,'selectors':selectors,'mode':mode,'destinationUdid':udid,'repetitionRelaunch':False,'point':str(point),'sourceManifest':str(root.parent/(root.name+'-source-manifest.json'))}
 # Missing/zero tests must never be counted as a successful point.
 if 'Executed 0 tests' in text:result['clean']=False;result['emptySelection']=True
 save(point/'point.json',result);collect(point,derived,udid)
 print(json.dumps(result),flush=True)
 return result


def main():
 repo=pathlib.Path.cwd(); out=pathlib.Path(os.environ['C1_EVIDENCE_ROOT']).resolve();out.mkdir(parents=True,exist_ok=True)
 baseline=os.environ['C1_BASELINE_REF']; udid=os.environ['C1_SIMULATOR_UDID']
 focused=os.environ.get('C1_FOCUSED_LIFECYCLE')=='true'
 if not re.fullmatch(r'[0-9a-f]{40}',baseline):raise RuntimeError('Exact immutable baseline object ref required')
 helptext=subprocess.run(['xcodebuild','-help'],capture_output=True,text=True).stderr
 (out/'xcodebuild-help.txt').write_text(helptext,encoding='utf-8')
 for option in ['-test-iterations','-test-repetition-relaunch-enabled']:
  if option not in helptext:raise RuntimeError('Unsupported repetition interface: '+option)
 variants={v:prepare_variant(repo,out/'sources'/v,v,baseline) for v in ['N0','N1']}
 harnesses=[digest((v/'Client/iPadZeroLagDisplayTests/C1LifetimeDiagnosticsTests.swift').read_bytes()) for v in variants.values()]
 if len(set(harnesses))!=1:raise RuntimeError('Neutral harness byte mismatch')
 all_points=[]; builds={}; start=time.monotonic()
 for mode in (['unsanitized'] if focused else ['unsanitized','asan','malloc-scribble']):
  runtime_env={'C1_DIAGNOSTIC_MODE':mode}
  if mode=='asan':runtime_env['ASAN_OPTIONS']='abort_on_error=1:detect_stack_use_after_return=1'
  if mode=='malloc-scribble':runtime_env['MallocScribble']='1'
  for variant,root in variants.items():
   if time.monotonic()-start>16000:raise RuntimeError('Campaign deadline reached before artifact-upload reserve')
   derived=out/'derived'/(variant+'-'+mode);point=out/variant/mode/'build'
   defines='DEBUG C1_LIFETIME_DIAGNOSTICS'+(' C1_CANDIDATE_SEMANTICS' if variant=='N1' else '')
   args=['xcodebuild','build-for-testing','-project','Client/iPadZeroLagDisplay/iPadCasting.xcodeproj','-scheme','iPadCasting','-destination','platform=iOS Simulator,id='+udid+',arch=x86_64','-derivedDataPath',str(derived),'-parallel-testing-enabled','NO','-enableAddressSanitizer','YES' if mode=='asan' else 'NO','ARCHS=x86_64','ONLY_ACTIVE_ARCH=YES','CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO','SWIFT_ACTIVE_COMPILATION_CONDITIONS='+defines]
   code=command(args,root,point/'xcodebuild.stdout-stderr.log')
   runs=list(derived.glob('Build/Products/*.xctestrun'))
   if code or len(runs)!=1:
    all_points.append({'variant':variant,'mode':mode,'clean':False,'crash':False,'buildFailure':True,'exit':code});collect(point,derived,udid);continue
   run=runs[0];patch_environment(run,runtime_env)
   save(point/'environment.json',{'environmentVariables':runtime_env,'defines':defines,'xctestrunSha256':digest(run.read_bytes()),'udid':udid,'sourceVariant':variant})
   builds[(variant,mode)]=(derived,run)
   count=20 if focused else (30 if mode=='unsanitized' else 10)
   selectors=['iPadCastingTests/C1DecoderLifecycleInstrumentationTests/testSingleCallerAndAsyncCleanupPreserveLifecycleMeasurements'] if focused else NEUTRAL
   result=run_test(root,out/variant/mode/'neutral',derived,run,udid,selectors,count,mode);result['variant']=variant;all_points.append(result)
   if variant=='N1' and not focused:
    for semantic,selectors in SEMANTIC.items():
     result=run_test(root,out/semantic/mode/'semantic',derived,run,udid,selectors,count,mode);result['variant']=semantic;all_points.append(result)
    if mode=='unsanitized':
     for sequence in ['S1ThenWifi','WifiThenS1','S2ThenWifi','WifiThenS2']:
      result=run_test(root,out/'sequences'/sequence,derived,run,udid,['iPadCastingTests/C1OrderedSequenceTests/test'+sequence],1,mode);result['variant']='SEQUENCE_'+sequence;result['orderedPairRepetitions']=20;all_points.append(result)
   save(out/'campaign-points.json',all_points)
 aggregates={v:{'clean':len([p for p in all_points if p.get('variant')==v])==3 and all(p['clean'] for p in all_points if p.get('variant')==v),'crash':any(p.get('crash',False) for p in all_points if p.get('variant')==v)} for v in ['N0','N1','S1','S2']}
 classification=classify(aggregates)
 sequences=[p for p in all_points if p.get('variant','').startswith('SEQUENCE_')]
 if aggregates['N0']['clean'] and aggregates['N1']['clean'] and aggregates['S1']['clean']:
  one=[p for p in sequences if p['variant']=='SEQUENCE_S1ThenWifi'];two=[p for p in sequences if p['variant']=='SEQUENCE_S2ThenWifi']
  if one and two and one[0]['crash'] and two[0]['clean']:classification='S1_FIXTURE_TEARDOWN_POLLUTION'
 full=[]
 if not focused and classification=='NON_REPRODUCIBLE' and len(sequences)==4 and all(p['clean'] for p in sequences) and all(p['clean'] for p in all_points):
  derived,run=builds[('N1','unsanitized')]
  for number in [1,2]:
   point=out/'full'/str(number)
   result=run_test(variants['N1'],point,derived,run,udid,[],1,'unsanitized')
   text=(point/'xcodebuild.stdout-stderr.log').read_text(encoding='utf-8',errors='replace')
   result['passedInventory']=sorted(re.findall(r"Test Case '([^']+)' passed",text))
   result['processRestarts']=len(re.findall(r'Restarting after unexpected exit',text))
   save(point/'point.json',result)
   full.append(result)
   if not result['clean']:break
  if len(full)==2 and full[0]['passedInventory']!=full[1]['passedInventory']:
   full[1]['clean']=False;full[1]['inventoryMismatch']=True
   save(out/'full'/'2'/'point.json',full[1])
 report={'canonicalHead':CANONICAL_SHA,'candidatePublicSha':CANDIDATE_SHA,'diagnosticPublicSha':os.environ['GITHUB_SHA'],'classification':classification,'focusedLifecycleOnly':focused,'aggregate':aggregates,'points':all_points,'fullNative':full,'NATIVE_STABILITY_GREEN':len(full)==2 and all(p['clean'] for p in full),'C1_GREEN':False,'LOCAL_FROZEN_AND_PARITY_CONFIRMATION':'REQUIRED_AFTER_NATIVE_RUNS','C1_COMMITTED':False,'C2_TOUCHED':False,'PRODUCTION_CHANGED':False,'IPA_CREATED':False,'HOST_PACKAGE_CREATED':False,'PHYSICAL':'PENDING','AUDIO_V1_CLOSED':False,'PRODUCTION_FREEZE':False}
 save(out/'classification.json',report)
 # A clean campaign is evidence, never authorization to commit or package.
 return 0 if ((len(all_points)==2 and all(p['clean'] for p in all_points)) if focused else report['NATIVE_STABILITY_GREEN']) else 1
if __name__=='__main__':
 try:sys.exit(main())
 except Exception as error:
  root=pathlib.Path(os.environ.get('C1_EVIDENCE_ROOT','.'))
  save(root/'STOP.json',{'CLASSIFICATION':'UNRESOLVED','error':str(error),'C1_GREEN':False,'C1_COMMITTED':False,'C2_TOUCHED':False})
  raise
