"""AU7 regressions plus AST-backed extracted-view scope checks (not a Swift type checker)."""
from pathlib import Path
import re
import unittest

APP = Path(__file__).resolve().parents[1] / 'iPadZeroLagDisplay'

class AU7Checks(unittest.TestCase):
    def test_extracted_views_do_not_implicitly_capture_outer_members_or_shadow_local_fields(self):
        try:
            from tree_sitter import Parser, Language
            import tree_sitter_swift
        except ImportError:
            self.skipTest('AST scope audit requires tree-sitter Swift; Xcode type checking remains mandatory')
        parser = Parser(Language(tree_sitter_swift.language()))
        files = ['ContentView.swift', 'SessionPanelOverlay.swift', 'SessionInputBar.swift', 'SettingsView.swift',
                 'GestureHelp.swift', 'DataTransfer/TransferCenterSheet.swift', 'RemoteControl/RemoteSpecialKeyBar.swift']
        for file in files:
            data = (APP / file).read_bytes()
            for outer in parser.parse(data).root_node.children:
                if outer.type != 'class_declaration':
                    continue
                names = {}
                for declaration in outer.children[-1].children:
                    if declaration.type in ('property_declaration', 'function_declaration'):
                        match = re.search(rb'\b(?:let|var|func)\s+(\w+)', data[declaration.start_byte:declaration.end_byte])
                        if match:
                            names[match[1].decode()] = declaration.type
                for child in outer.children[-1].children:
                    if child.type != 'class_declaration' or b'let owner:' not in data[child.start_byte:child.end_byte][:180]:
                        continue
                    locals_ = set()
                    def collect(node):
                        if node.type == 'simple_identifier' and node.parent.type in ('pattern', 'parameter', 'function_declaration'):
                            locals_.add(data[node.start_byte:node.end_byte].decode())
                        if node.type == 'simple_identifier' and node.parent.type == 'if_statement' and re.search(
                                rb'\b(?:if|guard)\s+let\s+$', data[node.parent.start_byte:node.start_byte]):
                            locals_.add(data[node.start_byte:node.end_byte].decode())
                        for item in node.children:
                            collect(item)
                    collect(child)
                    def inspect(node):
                        if node.type == 'simple_identifier':
                            name = data[node.start_byte:node.end_byte].decode().lstrip('$')
                            before = data[:node.start_byte].rstrip()
                            location = f'{file}:{node.start_point.row + 1}: {name}'
                            if name in names and name not in locals_ and node.parent.type not in (
                                    'value_argument_label', 'pattern', 'parameter', 'function_declaration'):
                                self.assertTrue(before.endswith(b'.') and not before.endswith(b'self.'), location)
                            if name in locals_ and names.get(name) == 'function_declaration':
                                self.assertFalse(before.endswith(b'owner.'), 'Local field shadows outer method: ' + location)
                        for item in node.children:
                            inspect(item)
                    inspect(child)

    def test_video_callback_uses_owner(self):
        text = (APP / 'ContentView.swift').read_text(encoding='utf-8')
        nested = text.split('struct ConnectedVideoSurface: View', 1)[1].split('struct DisconnectedDashboard:', 1)[0]
        self.assertIsNone(re.search(r'(?<![\w.])isSessionPanelOpen\s*=', nested))
        self.assertIn('owner.isSessionPanelOpen = true', nested)

    def test_action_image_uses_local_string(self):
        text = (APP / 'SessionPanelOverlay.swift').read_text(encoding='utf-8')
        nested = text.split('struct PanelActionButton: View', 1)[1].split('struct RouteAndControl:', 1)[0]
        self.assertIn('Image(systemName: icon)', nested)
        self.assertNotIn('Image(systemName: owner.icon)', nested)

    def test_panel_blocks_hardware_but_keeps_explicit_controls(self):
        text = (APP / 'ContentView.swift').read_text(encoding='utf-8')
        self.assertIn('!isSessionPanelOpen', text.split('private var remoteInputConfiguration:', 1)[1].split('@ViewBuilder', 1)[0])
        line = next(x for x in text.splitlines() if 'remoteKeyboardActive: owner.streamManager' in x)
        self.assertIn('!owner.isSessionPanelOpen', line)
        metal = (APP / 'MetalView.swift').read_text(encoding='utf-8')
        self.assertIn('active: sessionInputActive ?? remoteKeyboardActive', metal)
        pencil = (APP / 'PencilTouchView.swift').read_text(encoding='utf-8')
        self.assertIn('session.engine.hardwareCaptureEnabled', pencil)
        engine = (APP / 'Input/IPadInputEngine.swift').read_text(encoding='utf-8')
        gate = engine.split('func setHardwareCaptureEnabled', 1)[1].split('private var modifierStates', 1)[0]
        self.assertIn('quarantinedHardware.formUnion(physical)', gate)
        self.assertIn('retire()', gate)
        config = text.split('.onChange(of: remoteInputConfiguration)', 1)[1].split('remoteInput.bind', 1)[0]
        self.assertLess(config.index('setHardwareCaptureEnabled'), config.index('inputSession.releaseAll()'))

    def test_close_preserves_panel_drag(self):
        text = (APP / 'ContentView.swift').read_text(encoding='utf-8')
        self.assertIn('panelPresentationChanged(open, surfaceActive:', text)
        session = (APP / 'Input/IPadInputSession.swift').read_text(encoding='utf-8')
        self.assertIn('if open { releaseAll() }', session)
        self.assertIn('requiresRetirement(comparedTo: old)', text)

if __name__ == '__main__':
    unittest.main()
