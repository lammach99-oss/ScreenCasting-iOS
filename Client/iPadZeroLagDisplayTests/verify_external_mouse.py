"""Bounded AU8 ownership guards. Runtime behavior is covered by XCTest on iOS."""
from pathlib import Path
import unittest

APP = Path(__file__).resolve().parents[1] / 'iPadZeroLagDisplay'

def engine_body(name):
    text = (APP / 'Input/IPadInputEngine.swift').read_text(encoding='utf-8')
    start = text.index('func ' + name)
    brace = text.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[brace:end]

class ExternalMouseChecks(unittest.TestCase):
    def test_pencil_claim_retires_fingers_without_stealing_external_ownership(self):
        claim = engine_body('claimPencilScope(')
        self.assertNotIn('externalButtons.removeAll()', claim)
        self.assertNotIn('endAction("externalButtons")', claim)
        self.assertNotIn('endExternalScroll()', claim)
        self.assertNotIn('endExternalTransform()', claim)
        retire = engine_body('retireFingerScope(')
        self.assertIn('buttons.subtracting(externalButtons)', retire)
        self.assertIn('pencil == nil', retire)
        self.assertIn('quarantine.formUnion(contacts.keys)', retire)
        begin = engine_body('beginPencil(')
        self.assertIn('pointerAvailable: externalButtons.isEmpty', begin)
        apply = engine_body('applyPencil(')
        self.assertIn('if externalButtons.isEmpty', apply)

    def test_external_scroll_and_transform_preserve_physical_buttons(self):
        for name in ['beginExternalScroll(', 'beginExternalTransform(']:
            body = engine_body(name)
            self.assertNotIn('buttons.sorted()', body)
            self.assertNotIn('externalButtons.removeAll()', body)
            self.assertNotIn('endAction("externalButtons")', body)
            self.assertNotIn('pencilMouse.blocksFingers', body)
            self.assertIn('retireFingerScope()', body)
            self.assertLess(body.index('beginAction('), body.index('retireFingerScope()'))
        self.assertNotIn('pencilMouse.blocksFingers', engine_body('externalScroll('))
        zoom = engine_body('zoom(')
        self.assertIn('isExternalTransforming || !pencilMouse.blocksFingers', zoom)
        self.assertIn('!externalButtons.contains(1)', zoom)

    def test_all_external_start_paths_share_hardware_fence_but_terminals_do_not(self):
        for name in ['external(', 'hover(', 'zoom(', 'beginExternalScroll(',
                     'beginExternalTransform(', 'externalScroll(']:
            self.assertIn('hardwareCaptureEnabled', engine_body(name), name)
        for name in ['endExternalScroll(', 'endExternalTransform(', 'hoverExited(']:
            self.assertNotIn('guard enabled', engine_body(name), name)
            self.assertNotIn('guard hardwareCaptureEnabled', engine_body(name), name)
        external = engine_body('external(')
        self.assertIn('neutralRequired = true', external)
        self.assertIn('mask &', external)
        tests = (APP.parent / 'iPadZeroLagDisplayTests/PencilMouseTests.swift').read_text(encoding='utf-8')
        self.assertIn('testFencedUIKitScrollDoesNotResumeMidGestureAfterPanelClose', tests)
        for forbidden in ['sleep(', 'Task.sleep', 'AVAudioEngine']:
            self.assertNotIn(forbidden, tests)

    def test_palm_claim_does_not_reset_external_fractional_progress(self):
        text = (APP / 'Input/IPadInputEngine.swift').read_text(encoding='utf-8')
        self.assertIn('func retireFingerScope(', text)
        retire = engine_body('retireFingerScope(')
        self.assertIn('actionOwners.contains("pointer") else { return }', retire)
        self.assertIn('let preserveExternalRemainders', retire)
        self.assertIn('wheelFraction = priorWheel; fractional = priorRelative', retire)

    def test_ignored_tip_has_no_deferred_button_and_keeps_the_palm_lease(self):
        state = (APP / 'Input/PencilMouseState.swift').read_text(encoding='utf-8')
        begin = state.split('mutating func begin(', 1)[1].split('mutating func move(', 1)[0]
        self.assertIn('guard pointerAvailable', begin)
        self.assertLess(begin.index('activeID = id'), begin.index('guard pointerAvailable'))
        self.assertLess(begin.index('guard pointerAvailable'), begin.index('rightArmed = false'))
        self.assertIn('activeButton = nil; return [.claimFingers]', begin)
        move = state.split('mutating func move(', 1)[1].split('mutating func end(', 1)[0]
        self.assertIn('activeButton != nil', move)
        end = state.split('mutating func end(', 1)[1].split('mutating func retire(', 1)[0]
        self.assertIn('guard let button else { return [] }', end)

if __name__ == '__main__':
    unittest.main()
