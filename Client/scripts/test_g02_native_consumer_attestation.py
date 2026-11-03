import importlib.util, tempfile, unittest
from pathlib import Path

spec=importlib.util.spec_from_file_location('verifier',Path(__file__).with_name('verify_g02_native_consumer_attestation.py'))
v=importlib.util.module_from_spec(spec);spec.loader.exec_module(v)

class ConsumerContractTests(unittest.TestCase):
    def test_archive_path_rejects_traversal_absolute_drive_and_backslash(self):
        for p in ['../escape','/absolute','C:/escape','Client/ThirdPartyBuild/../escape','Client\\ThirdPartyBuild\\x','elsewhere/x']:
            with self.subTest(p=p),self.assertRaises(ValueError):v.relative_member(p)

    def test_archive_path_returns_only_native_relative_path(self):
        self.assertEqual(v.relative_member('Client/ThirdPartyBuild/build/a.a'),'build/a.a')

    def test_duplicate_manifest_keys_rejected(self):
        with self.assertRaises(ValueError):v.parse_manifest(b'Public SHA: a\nPublic SHA: b\n')

    def test_manifest_retains_producer_not_consumer(self):
        m=dict(v.EXPECTED_MANIFEST)
        v.verify_manifest(m)
        m['Public SHA']='126c10586959b8daee8337b2363c3ccdb9a9aa06'
        with self.assertRaises(ValueError):v.verify_manifest(m)

    def test_all_pinned_manifest_fields_fail_closed(self):
        for key in v.EXPECTED_MANIFEST:
            m=dict(v.EXPECTED_MANIFEST);m[key]='wrong'
            with self.subTest(key=key),self.assertRaises(ValueError):v.verify_manifest(m)

    def test_artifact_exact_identity_and_expiry(self):
        a={'id':v.ARTIFACT,'name':v.ARTIFACT_NAME,'expired':False,'workflow_run':{'id':v.RUN,'head_sha':v.PRODUCER}}
        v.verify_metadata(a,{'id':v.RUN,'head_sha':v.PRODUCER,'conclusion':'success','repository':{'full_name':v.REPO}})
        for key,value in [('id',1),('name','ScreenCasting-native-deps'),('expired',True)]:
            b=dict(a);b[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):v.verify_metadata(b,{'id':v.RUN,'head_sha':v.PRODUCER,'conclusion':'success','repository':{'full_name':v.REPO}})

    def test_tree_digest_sorted_records(self):
        import hashlib
        expected=hashlib.sha256(b'a  build/a\nb  xcframeworks/b\n').hexdigest()
        self.assertEqual(v.tree_digest({'xcframeworks/b':'b','build/a':'a'}),expected)

    def test_member_collision_rejected(self):
        seen=set();v.unique_path('build/A',seen)
        with self.assertRaises(ValueError):v.unique_path('build/a',seen)

    def test_toolchain_rejects_default_alias_and_wrong_sdk(self):
        good={'xcode':'16.4','build':'16F6','path':'/Applications/Xcode_16.4.app/Contents/Developer','deviceSdk':'18.5','simulatorSdk':'18.5'}
        v.verify_toolchain(good)
        for k,x in [('path','/Applications/Xcode.app'),('xcode','16.3'),('simulatorSdk','18.4')]:
            bad=dict(good);bad[k]=x
            with self.subTest(k=k),self.assertRaises(ValueError):v.verify_toolchain(bad)

    def test_consumer_sha_must_be_full_immutable_identity(self):
        for x in ['main','126c105','0'*40,'']:
            with self.assertRaises(ValueError):v.verify_consumer_sha(x)
        v.verify_consumer_sha('126c10586959b8daee8337b2363c3ccdb9a9aa06')

    def test_diagnostic_never_claims_product_readiness(self):
        a=v.diagnostic_record('126c10586959b8daee8337b2363c3ccdb9a9aa06',{'fixture':'x'})
        self.assertFalse(a['readyForNativeProductBuild'])
        self.assertEqual(a['producerSourceSha'],v.PRODUCER)
        self.assertNotEqual(a['producerSourceSha'],a['consumerSourceSha'])
        self.assertEqual(a['scope'],'DIAGNOSTIC_ONLY_NO_STAGE_NO_BUILD')

if __name__=='__main__':unittest.main()
