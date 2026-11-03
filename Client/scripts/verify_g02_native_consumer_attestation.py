"""Read-only isolated G02 diagnostic verifier. Never stages or builds dependencies."""
import argparse, hashlib, io, json, os, plistlib, re, subprocess, tarfile, zipfile
from pathlib import Path, PurePosixPath

REPO='lammach99-oss/ScreenCasting-iOS'
PRODUCER='82134888ffb0482c9a9724ac26c7dfff28b51c0e'
RUN=39005711789
ARTIFACT=12091540222
ARTIFACT_NAME='G02-native-dependencies-39005711789'
ARCHIVE_SHA='e84baf87981ecf71485de12adc226bce955e3c8c72f5fba89851056c51fb71d8'
TREE_SHA='1e8e79357502e214e9394ea4413a8b99c8f4ad16bdc165eceea5e51d4c4523f4'
MANIFEST_SHA='fd44acc28987ab3d49f6189e6d8ad064518a8bc3ad7d99b2b5318d820f3362e1'
PROVENANCE_SHA='cc50cb754e22bdf02228961dc3bb5084f1d060a976f182ab4b8cc43effef8b6e'
TOOLCHAIN_SHA='f86d715bcad676bb0fce4b0b48f2e76f71d509042632762f0d84ffa2aca33136'
EXPECTED_MANIFEST={
 'Manifest-Version':'1','Public SHA':PRODUCER,'Cache Schema':'g02-v1',
 'Cache Key':'g02-'+PRODUCER+'-openssl-3.5.7','Xcode Fingerprint':TOOLCHAIN_SHA,
 'Runner Architecture':'X64','OpenSSL Pin':'openssl-3.5.7-8cf17aaeb4599f8af87fefd810b5b5fee90fe69e',
 'libsrtp Pin':'24b3bf8f19b6f5ab4cd2bcceb4f4064efca86fd5','Opus Pin':'ddbe48383984d56acd9e1ab6a090c54ca6b735a6',
 'Device Variants':'OpenSSLCrypto:arm64,libsrtp2:arm64,libopus:arm64',
 'Simulator Variants':'OpenSSLCrypto:x86_64,libsrtp2:x86_64,libopus:x86_64',
 'Strict Validation':'PASS','Native Output Tree SHA-256':TREE_SHA}
METADATA_SHA='4798dcd53450d1b8bd450cf6e57b913e12a90a3baf6a63c051c5153c68cc3c1e'
METADATA=set()
for lib in ['libsrtp','opus']:
 for variant,config in [('device','Release-iphoneos'),('simulator','Release-iphonesimulator')]:
  root=f'build/{lib}-{variant}'
  METADATA.update([root+'/._'+config,root+'/._build',root+'/build/._'+config,
      root+'/build/EagerLinkingTBDs/._'+config,
      root+'/CMakeFiles/4.4.2/CompilerIdC/EagerLinkingTBDs/._'+('Debug-iphoneos' if variant=='device' else 'Debug-iphonesimulator')])

def require(ok,reason):
 if not ok:raise ValueError(reason)
def sha(data):return hashlib.sha256(data).hexdigest()
def verify_consumer_sha(value):require(bool(re.fullmatch('[0-9a-f]{40}',value)) and value!='0'*40,'full immutable consumer SHA required')
def safe_path(name):
 p=PurePosixPath(name)
 require(bool(name) and not p.is_absolute() and '..' not in p.parts and '\\' not in name and ':' not in name and name not in ('.','/'),'unsafe archive path')
 return p
def relative_member(name):
 p=safe_path(name);require(name.startswith('Client/ThirdPartyBuild/'),'unexpected native root')
 rel=name[len('Client/ThirdPartyBuild/'):].rstrip('/')
 require(rel.startswith(('build/','xcframeworks/')) or rel in ('build','xcframeworks'),'unexpected native subtree')
 return rel
def unique_path(name,seen):
 require(name.casefold() not in seen,'duplicate/case collision');seen.add(name.casefold())
def parse_manifest(raw):
 values={}
 for line in raw.decode('utf-8').splitlines():
  require(': ' in line,'invalid manifest line');k,v=line.split(': ',1)
  require(k not in values,'duplicate manifest field');values[k]=v
 return values
def verify_manifest(values):require(values==EXPECTED_MANIFEST,'pinned producer manifest mismatch')
def verify_metadata(a,r):
 require(a.get('id')==ARTIFACT and a.get('name')==ARTIFACT_NAME and a.get('expired') is False,'artifact identity/expiry')
 require(a.get('workflow_run',{}).get('id')==RUN and a['workflow_run'].get('head_sha')==PRODUCER,'artifact run/producer')
 require(r.get('id')==RUN and r.get('head_sha')==PRODUCER and r.get('conclusion')=='success' and r.get('repository',{}).get('full_name')==REPO,'run identity/success')
def verify_toolchain(t):
 require(t=={'xcode':'16.4','build':'16F6','path':'/Applications/Xcode_16.4.app/Contents/Developer','deviceSdk':'18.5','simulatorSdk':'18.5'},'consumer toolchain mismatch')
def tree_digest(files):return sha(''.join(h+'  '+p+'\n' for p,h in sorted(files.items(),key=lambda x:x[0].encode())).encode())
def diagnostic_record(consumer,evidence):
 verify_consumer_sha(consumer)
 return {'schema':'g02-consumer-diagnostic-v1','producerSourceSha':PRODUCER,'consumerSourceSha':consumer,
  'runId':RUN,'artifactId':ARTIFACT,'scope':'DIAGNOSTIC_ONLY_NO_STAGE_NO_BUILD',
  'readyForNativeProductBuild':False,'sourceQualification':'OPEN_REQUIRES_GATE_A_S_L_PUBLIC_ADAPTER_MAPPING',
  'nativeMachORequalification':'NOT_RUN_RETAINED_NATIVE_VERIFICATION_ONLY','evidence':evidence}
def native_archive(raw,provenance):
 require(sha(raw)==ARCHIVE_SHA,'archive hash mismatch before inspection')
 expected=provenance['nativeFileSha256'];require(len(expected)==1922,'qualified native file inventory count')
 files={};meta={};seen=set();size=0;plists={}
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as archive:
  for member in archive:
   rel=relative_member(member.name);unique_path(member.name.rstrip('/'),seen)
   require(member.isdir() or member.isfile(),'symlink/hardlink/special member forbidden')
   require(member.size>=0 and member.size<=256*1024*1024,'member size bound')
   size+=member.size;require(size<=1024*1024*1024,'archive uncompressed size bound')
   if member.isdir():continue
   data=archive.extractfile(member).read();h=sha(data)
   if rel in METADATA:
    require(h==METADATA_SHA and data[:4]==bytes.fromhex('00051607'),'metadata content mismatch');meta[rel]=h
   else:
    require(rel in expected and h==expected[rel],'unknown/missing/changed native file');files[rel]=h
   if rel.endswith('.xcframework/Info.plist'):plists[rel]=plistlib.loads(data)
 require(files==expected and set(meta)==METADATA,'exact native/metadata set mismatch')
 require(tree_digest(files)==TREE_SHA,'native tree digest mismatch')
 require(set(plists)=={'xcframeworks/'+n+'/Info.plist' for n in ['OpenSSLCrypto.xcframework','libsrtp2.xcframework','libopus.xcframework']},'framework inventory mismatch')
 for p in plists.values():
  libs=p['AvailableLibraries'];require(len(libs)==2,'variant count')
  require({(tuple(l['SupportedArchitectures']),l['SupportedPlatform'],l.get('SupportedPlatformVariant','device')) for l in libs}=={(('arm64',),'ios','device'),(('x86_64',),'ios','simulator')},'variant arch/platform')
 return {'regularFileCount':len(files),'metadataCount':len(meta),'nativeTreeSha256':TREE_SHA,'archiveSha256':ARCHIVE_SHA}
def verify_evidence(evidence):
 required={'native-deps.manifest.txt':MANIFEST_SHA,'provenance.json':PROVENANCE_SHA,'toolchain.txt':TOOLCHAIN_SHA}
 for name,h in required.items():require(sha(evidence[name])==h,'pinned evidence mismatch: '+name)
 verify_manifest(parse_manifest(evidence['native-deps.manifest.txt']))
 provenance=json.loads(evidence['provenance.json'])
 require(provenance['publicSha']==PRODUCER and provenance['canonicalAuthority']=='573b3d7dfd2818c37ac39d10fe03f1c8e3988bbf','provenance producer authority')
 result=native_archive(evidence['G02-native-deps-openssl-3.5.7.tar.gz'],provenance)
 result.update({'producerManifestSha256':MANIFEST_SHA,'producerProvenanceSha256':PROVENANCE_SHA,'producerToolchainSha256':TOOLCHAIN_SHA})
 return result
def read_evidence_zip(path,artifact):
 raw=path.read_bytes();require('sha256:'+sha(raw)==artifact['digest'],'official artifact ZIP digest mismatch')
 allowed={'builder-before.sh','G02-native-deps-openssl-3.5.7.tar.gz','G02-native-deps-openssl-3.5.7.tar.gz.sha256','native-build.log','native-deps.manifest.txt','native-verify.log','pin-GREEN.log','pin-RED.log','provenance.json','toolchain.txt'}
 evidence={};seen=set();total=0
 with zipfile.ZipFile(io.BytesIO(raw)) as archive:
  for m in archive.infolist():
   p=safe_path(m.filename);unique_path(m.filename.rstrip('/'),seen)
   require((m.external_attr>>16)&0o170000 not in (0o120000,),'ZIP symlink forbidden')
   if m.is_dir():continue
   require(len(p.parts)==1 and p.name in allowed,'unknown ZIP envelope member')
   total+=m.file_size;require(total<=512*1024*1024 and not m.flag_bits&1,'ZIP envelope bound/encryption')
   evidence[p.name]=archive.read(m)
 require(set(evidence)==allowed,'incomplete evidence envelope')
 return evidence
def inspect_local_evidence(directory):
 # Explicit offline mode trusts only pinned core evidence/archive bytes, not a claimed GitHub acquisition.
 names=['native-deps.manifest.txt','provenance.json','toolchain.txt','G02-native-deps-openssl-3.5.7.tar.gz']
 return verify_evidence({n:(directory/n).read_bytes() for n in names})
def consumer_inventory(root,consumer):
 def git(*args):return subprocess.check_output(['git','--no-optional-locks','-C',str(root),*args])
 require(git('rev-parse','HEAD').decode().strip()==consumer,'consumer checkout SHA mismatch')
 require(not git('diff','--name-only') and not git('diff','--cached','--name-only'),'consumer checkout tracked dirty')
 paths=git('ls-files','-z','Client','.github/workflows/ios-public-ci.yml').split(b'\0');files={}
 for path in paths:
  if not path:continue
  name=path.decode('utf-8');p=root/name
  require(p.is_file() and not p.is_symlink(),'consumer source missing/symlink')
  files[name]=sha(p.read_bytes())
 require(bool(files),'consumer source inventory empty')
 return {'files':files,'filesManifestSha256':sha(json.dumps(files,sort_keys=True,separators=(',',':')).encode()),'qualified':False}
def main():
 ap=argparse.ArgumentParser(description=__doc__)
 group=ap.add_mutually_exclusive_group(required=True);group.add_argument('--offline-evidence',type=Path);group.add_argument('--artifact-zip',type=Path)
 ap.add_argument('--artifact-metadata',type=Path);ap.add_argument('--run-metadata',type=Path)
 ap.add_argument('--consumer-sha',required=True);ap.add_argument('--consumer-root',type=Path);ap.add_argument('--output',required=True,type=Path)
 args=ap.parse_args();verify_consumer_sha(args.consumer_sha)
 require(not args.output.exists(),'output exists')
 if args.consumer_root:require(args.consumer_root.resolve() not in args.output.resolve().parents,'output must be outside checkout')
 if args.offline_evidence:
  result=inspect_local_evidence(args.offline_evidence);result['acquisition']='OFFLINE_PINNED_EVIDENCE_NOT_GITHUB_ACQUISITION_ATTESTATION'
 else:
  require(args.artifact_metadata is not None and args.run_metadata is not None and args.consumer_root is not None,'official metadata/consumer root required')
  artifact=json.loads(args.artifact_metadata.read_text());run=json.loads(args.run_metadata.read_text());verify_metadata(artifact,run)
  result=verify_evidence(read_evidence_zip(args.artifact_zip,artifact))
  result['acquisition']='OFFICIAL_METADATA_AND_ARTIFACT_ZIP_DIGEST_CHECKED'
  def get(*cmd):return subprocess.check_output(cmd,text=True).strip()
  xc=get('xcodebuild','-version').splitlines()
  tool={'xcode':xc[0].removeprefix('Xcode '),'build':xc[1].removeprefix('Build version '),'path':get('xcode-select','-p'),'deviceSdk':get('xcrun','--sdk','iphoneos','--show-sdk-version'),'simulatorSdk':get('xcrun','--sdk','iphonesimulator','--show-sdk-version')}
  verify_toolchain(tool);result['observedConsumerToolchain']=tool
 if args.consumer_root:result['consumerSourceInventory']=consumer_inventory(args.consumer_root,args.consumer_sha)
 output=diagnostic_record(args.consumer_sha,result)
 args.output.parent.mkdir(parents=True,exist_ok=True)
 with args.output.open('x',encoding='utf-8') as f:json.dump(output,f,indent=2);f.write('\n')
 print('G02_DIAGNOSTIC_PROVENANCE_VERIFIED_PRODUCT_READINESS_OPEN')
if __name__=='__main__':main()
