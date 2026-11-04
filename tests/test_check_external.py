import tempfile
import unittest
from pathlib import Path

from tools.bootstrap.check_external import validate


class CheckExternalPathTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.base = Path(self.temp_dir.name)
        self.root = self.base / 'repo'
        self.root.mkdir()
        (self.root / 'references').mkdir()
        (self.root / 'references' / 'source.md').write_text('source', encoding='utf-8')
        (self.root / 'evidence').mkdir()
        (self.root / 'evidence' / 'proof.md').write_text('proof', encoding='utf-8')
        (self.base / 'outside.md').write_text('outside', encoding='utf-8')

    def tearDown(self):
        self.temp_dir.cleanup()

    def entry(self, **overrides):
        entry = {
            'id': 'sample',
            'repo': 'owner/repo',
            'url': 'https://github.com/owner/repo',
            'ref': '0' * 40,
            'role': 'verification',
            'status': 'registered',
            'integration_stage': 'P0',
            'license_note': 'test',
            'license_review': 'test',
            'checked_on': '2026-09-25',
            'purpose': 'test',
            'validation': 'NOT_RUN',
            'reference': 'references/source.md',
        }
        entry.update(overrides)
        return entry

    def errors(self, entry):
        return validate({'schema_version': 1, 'dependencies': [entry]}, self.root)

    def test_accepts_existing_reference_inside_repo(self):
        self.assertEqual([], self.errors(self.entry()))

    def test_rejects_reference_outside_repo(self):
        self.assertTrue(any('out-of-repo reference' in error
                            for error in self.errors(self.entry(reference='../outside.md'))))

    def test_rejects_missing_reference_file(self):
        self.assertTrue(any('out-of-repo reference' in error
                            for error in self.errors(self.entry(reference='references/missing.md'))))

    def test_active_entry_accepts_existing_evidence_inside_repo(self):
        entry = self.entry(status='active', validation='PASS', evidence='evidence/proof.md')
        self.assertEqual([], self.errors(entry))

    def test_active_entry_rejects_outside_and_missing_evidence(self):
        outside_errors = self.errors(self.entry(status='active', validation='PASS', evidence='../outside.md'))
        missing_errors = self.errors(self.entry(status='active', validation='PASS', evidence='evidence/missing.md'))
        self.assertTrue(any('active requires PASS and local evidence' in error for error in outside_errors))
        self.assertTrue(any('active requires PASS and local evidence' in error for error in missing_errors))


if __name__ == '__main__':
    unittest.main()
