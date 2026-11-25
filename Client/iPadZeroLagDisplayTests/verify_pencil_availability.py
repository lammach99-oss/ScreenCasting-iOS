"""AST availability dominance for audited Pencil APIs; Xcode remains the SDK type checker."""
from pathlib import Path
import re
import unittest

from tree_sitter import Language, Parser
import tree_sitter_swift

APP = Path(__file__).resolve().parents[1] / 'iPadZeroLagDisplay'
RULES = [
    (rb'\bUIPencilInteraction\s*\(\s*delegate\s*:', (17, 5)),
    (rb'\bUIPencilInteraction\s*\.\s*(?:Tap|Squeeze|Phase)\b', (17, 5)),
    (rb'\bUIPencilHoverPose\b', (17, 5)),
    (rb'\b(?:preferredSqueezeAction|hoverPose|rollAngle|showContextualPalette)\b', (17, 5)),
    (rb'\bdidReceive(?:Tap|Squeeze)\b', (17, 5)),
]


def ios_version(text, prefix):
    match = re.search(prefix + rb'\s*\(\s*iOS\s+(\d+)(?:\.(\d+))?', text)
    return (int(match[1]), int(match[2] or 0)) if match else (0, 0)


def availability_violations(text, deployment=(17, 0)):
    data = text.encode('utf-8')
    tree = Parser(Language(tree_sitter_swift.language())).parse(data)
    if tree.root_node.has_error:
        raise ValueError('Availability audit requires valid Swift syntax')
    violations = []
    for pattern, required in RULES:
        for match in re.finditer(pattern, data):
            leaf = tree.root_node.descendant_for_byte_range(match.start(), match.end() - 1)
            node, minimum, ignored = leaf, deployment, False
            while node:
                if 'comment' in node.type or node.type in (
                        'line_string_literal', 'multi_line_string_literal', 'raw_string_literal', 'string_literal'):
                    ignored = True
                    break
                for child in node.children:
                    if child.type == 'modifiers':
                        minimum = max(minimum, ios_version(data[child.start_byte:child.end_byte], rb'@available'))
                if node.type == 'if_statement':
                    condition = next((child for child in node.children if child.type == 'availability_condition'), None)
                    opening = next((child for child in node.children if child.type == '{'), None)
                    otherwise = next((child for child in node.children if child.type == 'else'), None)
                    end = otherwise.start_byte if otherwise else node.end_byte
                    if condition and opening and opening.end_byte <= match.start() < end:
                        minimum = max(minimum, ios_version(data[condition.start_byte:condition.end_byte], rb'#available'))
                if node.type == 'statements':
                    for child in node.children:
                        if child.type == 'guard_statement' and child.end_byte <= match.start():
                            minimum = max(minimum, ios_version(data[child.start_byte:child.end_byte], rb'#available'))
                node = node.parent
            if not ignored and minimum < required:
                line = data.count(b'\n', 0, match.start()) + 1
                violations.append(f'{line}: {match[0].decode()} needs iOS {required[0]}.{required[1]}')
    return violations


class PencilAvailabilityChecks(unittest.TestCase):
    def test_every_audited_post_deployment_api_is_guarded(self):
        project = (APP / 'iPadCasting.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
        targets = re.findall(r'IPHONEOS_DEPLOYMENT_TARGET\s*=\s*(\d+)\.(\d+)', project)
        self.assertEqual(targets, [('17', '0')] * 4, 'Re-audit APIs if the deployment target changes')
        files = list(APP.glob('Pencil*.swift')) + list((APP / 'Input').glob('*.swift')) + [APP / 'MetalView.swift']
        for path in files:
            with self.subTest(file=path.name):
                self.assertEqual(availability_violations(path.read_text(encoding='utf-8')), [], path.name)

    def test_initializer_retains_legacy_delegate_setup(self):
        text = (APP / 'PencilTouchView.swift').read_text(encoding='utf-8')
        install = text.split('private func installPencilMouseInteraction()', 1)[1].split('pencilArmedLabel.text', 1)[0]
        self.assertIn('if #available(iOS 17.5, *)', install)
        self.assertIn('let interaction = UIPencilInteraction()', install)
        self.assertIn('interaction.delegate = self', install)
        self.assertIn('addInteraction(interaction)', install)
        legacy = text.split('func pencilInteractionDidTap(', 1)[1].split('@available', 1)[0]
        self.assertIn('if #available(iOS 17.5, *) { return }', legacy)
        self.assertIn('togglePencilRight()', legacy)

    def test_scanner_rejects_unguarded_weak_sibling_and_else_guards(self):
        samples = [
            'func f() { _ = UIPencilInteraction(delegate: self) }',
            'func f() { if #available(iOS 17.0, *) { _ = UIPencilInteraction(delegate: self) } }',
            'func f() { if #available(iOS 17.5, *) {} else { _ = UIPencilInteraction(delegate: self) } }',
            'func f() { if #available(iOS 17.5, *) {}\n _ = UIPencilInteraction(delegate: self) }',
            '@available(iOS 17.4, *) func f(_ tap: UIPencilInteraction.Tap) {}',
            'func f() { _ = UIPencilInteraction.preferredSqueezeAction }',
            'func f(_ pose: UIPencilHoverPose) { _ = pose.rollAngle }',
        ]
        for sample in samples:
            with self.subTest(source=sample):
                self.assertTrue(availability_violations(sample))

    def test_scanner_accepts_local_declaration_and_guard_dominance(self):
        samples = [
            'func f() { if #available(iOS 17.5, *) { _ = UIPencilInteraction(delegate: self) } }',
            '@available(iOS 17.5, *) func f(_ tap: UIPencilInteraction.Tap) {}',
            '@available(iOS 18.0, *) class V { func f() { _ = UIPencilInteraction.preferredSqueezeAction } }',
            'func f() { guard #available(iOS 17.5, *) else { return }; _ = UIPencilInteraction(delegate: self) }',
        ]
        for sample in samples:
            with self.subTest(source=sample):
                self.assertEqual(availability_violations(sample), [])

    def test_production_guard_removal_and_weakening_are_detected(self):
        text = (APP / 'PencilTouchView.swift').read_text(encoding='utf-8')
        for changed in [
                text.replace('if #available(iOS 17.5, *)', 'if #available(iOS 17.0, *)', 1),
                text.replace('@available(iOS 17.5, *)', '@available(iOS 17.4, *)'),
                text.replace('@available(iOS 17.5, *)', '')]:
            self.assertTrue(availability_violations(changed), 'A removed/weak Pencil guard escaped detection')


if __name__ == '__main__':
    unittest.main()
