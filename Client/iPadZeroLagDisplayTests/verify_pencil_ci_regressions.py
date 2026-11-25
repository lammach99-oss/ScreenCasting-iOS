"""CI 44011899449 source regressions; SDK behavior remains an XCTest gate."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'iPadZeroLagDisplay'
TESTS = ROOT / 'iPadZeroLagDisplayTests'


class PencilCIRegressionChecks(unittest.TestCase):
    def test_app_recognizers_are_identifiable_restricted_and_noncancelling(self):
        text = (APP / 'PencilTouchView.swift').read_text(encoding='utf-8')
        # Audit every app-created recognizer, including future additions. UIKit
        # may privately install extra recognizers for UIPencilInteraction.
        blocks = re.findall(r'let (\w+) = UI\w+GestureRecognizer\([^\n]*\)(.*?)addGestureRecognizer\(\1\)',
                            text, flags=re.S)
        self.assertEqual(len(blocks), 5)
        names = []
        for variable, body in blocks:
            self.assertIn(variable + '.name = "IPadInput.', body)
            name = re.search(r'\.name = "([^"]+)"', body)
            self.assertIsNotNone(name)
            names.append(name[1])
            allowed = re.search(r'\.allowedTouchTypes = ([^\n]+)', body)
            self.assertIsNotNone(allowed)
            self.assertTrue(allowed[1] == '[]' or
                            any(t in allowed[1] for t in ['TouchType.pencil.rawValue', 'TouchType.indirectPointer.rawValue']))
            self.assertIn(variable + '.cancelsTouchesInView = false', body)
        self.assertEqual(len(set(names)), 5)

    def test_recognizer_xctest_checks_owned_admission_instead_of_global_count(self):
        text = (TESTS / 'WireProtocolTests.swift').read_text(encoding='utf-8')
        body = text.split('func testRecognizersCannotConsumeDirectFingerInput()', 1)[1].split('\n    func ', 1)[0]
        self.assertNotIn('XCTAssertEqual(hover.count, 1)', body)
        for token in ['hasPrefix("IPadInput.")', 'XCTAssertEqual(owned.count, 5)',
                      'UITouch.TouchType.direct.rawValue', 'XCTAssertFalse(recognizer.cancelsTouchesInView',
                      'IPadInput.pencilHover', 'IPadInput.pointerHover', 'IPadInput.continuousScroll',
                      'IPadInput.discreteScroll', 'IPadInput.pinch']:
            self.assertIn(token, body)

    def test_modifier_xctest_distinguishes_pencil_mouse_from_direct_touch(self):
        text = (TESTS / 'IPadInputV2Tests.swift').read_text(encoding='utf-8')
        body = text.split('func testCommandShortcutThenEveryPointerActionRestoresSameSideBeforeDown()', 1)[1].split('\n    func ', 1)[0]
        self.assertNotIn('case "direct","pencil":', body)
        for token in ['case "pencil":', 'XCTAssertEqual(out, [.key(ctrl,0),.pointer(0,0,0,0),.button(1,0,1)]',
                      'XCTAssertEqual(out, [.key(ctrl,0),.touch(.down,1,.zero,255)]',
                      'XCTAssertEqual(Array(out.suffix(3)), [.pointer(0,0,0,0),.button(1,1,1),.key(ctrl,1)]',
                      'XCTAssertLessThan(controlDown,pointerDown,action)']:
            self.assertIn(token, body)


if __name__ == '__main__':
    unittest.main()
