import pathlib
import re
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
BUILDER = pathlib.Path(sys.argv.pop()) if len(sys.argv) > 1 else ROOT / 'Client/scripts/build_ios_dependencies.sh'


class DependencyPinTests(unittest.TestCase):
    def test_exact_openssl_tag_and_commit(self):
        text = BUILDER.read_text()
        self.assertIn('OPENSSL_REV="openssl-3.5.7"', text)
        self.assertIn('OPENSSL_TAG_OBJECT="6ca677c395a4ae4472a12c5857c122ec33b36f66"', text)
        self.assertIn('OPENSSL_COMMIT="8cf17aaeb4599f8af87fefd810b5b5fee90fe69e"', text)
        self.assertRegex(text, r'rev-parse HEAD\).*OPENSSL_COMMIT')

    def test_media_pins_and_platform_policy_unchanged(self):
        text = BUILDER.read_text()
        for literal in ['LIBSRTP_REV=24b3bf8f19b6f5ab4cd2bcceb4f4064efca86fd5',
                        'OPUS_REV=ddbe48383984d56acd9e1ab6a090c54ca6b735a6',
                        'OPENSSL_IPAD_DEVICE_TARGET="ios64-xcrun"',
                        'OPENSSL_IPAD_SIMULATOR_TARGET="iossimulator-x86_64-xcrun"',
                        'build_openssl iphoneos arm64 device',
                        'build_openssl iphonesimulator x86_64 simulator',
                        'verify_ios_dependency_artifacts.sh']:
            self.assertIn(literal, text)


if __name__ == '__main__':
    unittest.main()
