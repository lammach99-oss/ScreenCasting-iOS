"""Bounded Pencil source contracts. XCTest remains the behavior/runtime gate."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'iPadZeroLagDisplay'

class PencilMouseChecks(unittest.TestCase):
    def assertIn(self, member, container, msg=None):
        self.assertTrue(member in container, msg or 'Missing Pencil contract: ' + member)
    def test_pure_clock_driven_mouse_state_exists(self):
        path = APP / 'Input/PencilMouseState.swift'
        self.assertTrue(path.exists(), 'Pencil has no precise-mouse state machine yet')
        text = path.read_text(encoding='utf-8')
        for token in ['struct PencilMouseState', 'case claimFingers', 'case move(CGPoint)',
                      'case button(UInt8, Bool)', '5.0', '0.400', 'clock()', 'func retire()']:
            self.assertIn(token, text)
        for token in ['UIKit', 'pressure', 'tilt', 'sleep(']:
            self.assertNotIn(token, text)

    def test_engine_reuses_transactions_and_surface_fence_for_pencil(self):
        text = (APP / 'Input/IPadInputEngine.swift').read_text(encoding='utf-8')
        for token in ['private var pencilMouse: PencilMouseState', 'func pencilHover(at',
                      'func togglePencilRight()', 'precisePencilAvailable', 'pencilMouse.blocksFingers',
                      'case let .button(b, down): button(b, down)', 'beginAction("pencil")',
                      'endAction("pencil")']:
            self.assertIn(token, text)
        begin = text.split('func begin(id:', 1)[1].split('private func geometry()', 1)[0]
        self.assertNotIn('touch(.down, id: id, at: p, pressure: 255)', begin)

    def test_uikit_separates_hover_and_guards_pencil_interactions(self):
        text = (APP / 'PencilTouchView.swift').read_text(encoding='utf-8')
        for token in ['UIPencilInteractionDelegate', 'handlePencilHover', 'pencilHover.allowedTouchTypes',
                      'hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]',
                      '@available(iOS 17.5, *)', 'didReceiveSqueeze squeeze:', 'squeeze.phase == .ended',
                      'UIPencilInteraction.preferredTapAction != .ignore',
                      'UIPencilInteraction.preferredSqueezeAction != .ignore',
                      'Pencil: next touch right-click']:
            self.assertIn(token, text)
        route = (APP / 'Input/IPadInputRouting.swift').read_text(encoding='utf-8')
        self.assertIn('engine.precisePencilAvailable = remote ? features & 2 != 0 && ready : pointerV2', route)

    def test_new_sources_and_behavior_cases_are_in_their_targets(self):
        project = (APP / 'iPadCasting.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
        for name in ['PencilMouseState.swift', 'PencilMouseTests.swift']:
            self.assertIn('/* ' + name + ' in Sources */', project)
        self.assertIn('path = Input/PencilMouseState.swift;', project)
        tests = (ROOT / 'iPadZeroLagDisplayTests/PencilMouseTests.swift').read_text(encoding='utf-8')
        for name in ['testHoverAndTipAreAbsoluteWithBalancedLeftButton',
                     'testRightArmTogglesExpiresAndIsConsumedByExactlyOneTip',
                     'testHoverPreemptsFingerAndGraceCannotReviveAPalm',
                     'testPanelAndUnavailablePeerFencePencilButTerminalsStillRetire',
                     'testAllThreeRoutesEncodeRightDragAndRetireWithTheOriginalAuthority',
                     'testPencilOwnsCommandThroughLongDragAndRetiresOnce',
                     'testArmedIndicatorPublishesExpiryAndPanelRetirement',
                     'testUIKitHoverUsesVideoViewportAndGeometryChangeRetiresOldButton']:
            self.assertIn(name, tests)
        for token in ['sleep(', 'AVAudioEngine', 'Task.sleep']:
            self.assertNotIn(token, tests)

    def test_palm_fences_cover_fingers_but_not_external_scroll_and_coordinate_adapter(self):
        engine = (APP / 'Input/IPadInputEngine.swift').read_text(encoding='utf-8')
        finger = engine.split('func fingerScroll(', 1)[1].split('\n    func ', 1)[0]
        self.assertIn('!pencilMouse.blocksFingers', finger)
        for name in ['beginExternalScroll()', 'beginExternalTransform()', 'externalScroll(']:
            body = engine.split('func ' + name, 1)[1].split('\n    func ', 1)[0]
            self.assertNotIn('pencilMouse.blocksFingers', body)
        self.assertIn('isExternalTransforming || !pencilMouse.blocksFingers', engine)
        pencil = (APP / 'PencilTouchView.swift').read_text(encoding='utf-8')
        adapter = pencil.split('func routePencilHover(', 1)[1].split('private func togglePencilRight()', 1)[0]
        self.assertIn('contentViewport?.normalizedPoint(for: point, in: bounds)', adapter)
        self.assertIn('inputSession?.engine.pencilHover(at: mapped)', adapter)
        demo = (APP / 'PencilOverlayView.swift').read_text(encoding='utf-8').split('// MARK: - Pattern B:', 1)[0]
        self.assertIn('.iPadInputSession(inputSession)', demo)
        self.assertNotIn('sendTouchEvent(', demo)

if __name__ == '__main__':
    unittest.main()
