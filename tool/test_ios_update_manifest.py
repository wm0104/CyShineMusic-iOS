import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile

from create_ios_update_manifest import create_manifest


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.ipa = self.root / 'CyShineMusic-unsigned.ipa'
        self.app = {
            'CFBundleIdentifier': 'com.cyshine.music',
            'CFBundleShortVersionString': '2.0.9',
            'CFBundleVersion': '123',
        }
        self.widget = dict(self.app, CFBundleIdentifier='com.cyshine.music.widget')
        self.tag = 'ios-v2.0.9'
        self.commit = 'a' * 40
        self.make_ipa()

    def make_ipa(self, omit=None, binary=False):
        fmt = plistlib.FMT_BINARY if binary else plistlib.FMT_XML
        with zipfile.ZipFile(self.ipa, 'w') as archive:
            for path, data in [
                ('Payload/Runner.app/Info.plist', self.app),
                ('Payload/Runner.app/PlugIns/CyShineMusicWidget.appex/Info.plist', self.widget),
            ]:
                if path != omit:
                    archive.writestr(path, plistlib.dumps(data, fmt=fmt))
            archive.writestr('Payload/Runner.app/Runner', b'fixture')

    def manifest(self, **kwargs):
        return create_manifest(self.ipa, kwargs.get('tag', self.tag),
                               kwargs.get('commit', self.commit),
                               kwargs.get('notes', '已有发行说明'))

    def test_manifest_and_actual_hash(self):
        result = self.manifest()
        base = 'https://github.com/wm0104/CyShineMusic-iOS/releases'
        self.assertEqual(result, {
            'schema': 1, 'repository': 'wm0104/CyShineMusic-iOS',
            'version': '2.0.9', 'build': 123, 'tag': self.tag,
            'page_url': base + '/tag/' + self.tag, 'name': '2.0.9',
            'notes': '已有发行说明', 'source_commit': self.commit,
            'ipa': {'name': self.ipa.name,
                    'url': base + '/download/' + self.tag + '/' + self.ipa.name,
                    'sha256': hashlib.sha256(self.ipa.read_bytes()).hexdigest()},
        })

    def test_binary_plists_and_notes_limit(self):
        self.make_ipa(binary=True)
        self.assertEqual(self.manifest(notes='音' * 17000)['notes'], '音' * 16384)

    def test_version_mismatch(self):
        with self.assertRaises(ValueError):
            self.manifest(tag='ios-v2.0.8')

    def test_invalid_tags_and_commits(self):
        for tag in ('2.0.9', 'ios-v2.0', 'ios-v2.0.9/evil', 'ios-v2.0.9\n'):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                self.manifest(tag=tag)
        for commit in ('a' * 39, 'g' * 40, 'A' * 40, 'a' * 40 + '\n'):
            with self.subTest(commit=commit), self.assertRaises(ValueError):
                self.manifest(commit=commit)

    def test_invalid_builds(self):
        for build in ('0', '-1', '1.2', '01', '123\n', '', 123, True):
            with self.subTest(build=build):
                self.app['CFBundleVersion'] = build
                self.make_ipa()
                with self.assertRaises(ValueError):
                    self.manifest()

    def test_wrong_bundle_identifiers(self):
        for bundle in (self.app, self.widget):
            original = bundle['CFBundleIdentifier']
            bundle['CFBundleIdentifier'] = 'com.other.music'
            self.make_ipa()
            with self.assertRaises(ValueError):
                self.manifest()
            bundle['CFBundleIdentifier'] = original

    def test_widget_version_and_build_must_match(self):
        for key, value in (('CFBundleShortVersionString', '2.0.8'),
                           ('CFBundleVersion', '122')):
            original = self.widget[key]
            self.widget[key] = value
            self.make_ipa()
            with self.assertRaises(ValueError):
                self.manifest()
            self.widget[key] = original

    def test_missing_plists(self):
        for path in ('Payload/Runner.app/Info.plist',
                     'Payload/Runner.app/PlugIns/CyShineMusicWidget.appex/Info.plist'):
            self.make_ipa(omit=path)
            with self.assertRaises(ValueError):
                self.manifest()

    def test_invalid_zip_and_plist(self):
        self.ipa.write_bytes(b'not a zip')
        with self.assertRaises(ValueError):
            self.manifest()
        self.make_ipa(omit='Payload/Runner.app/Info.plist')
        with zipfile.ZipFile(self.ipa, 'a') as archive:
            archive.writestr('Payload/Runner.app/Info.plist', b'invalid plist')
        with self.assertRaises(ValueError):
            self.manifest()

    def test_corrupt_zip_crc(self):
        data = self.ipa.read_bytes()
        self.assertEqual(data.count(b'fixture'), 1)
        self.ipa.write_bytes(data.replace(b'fixture', b'Fixture'))
        with self.assertRaises(ValueError):
            self.manifest()

    def test_unexpected_ipa_filename(self):
        renamed = self.ipa.with_name('other.ipa')
        self.ipa.rename(renamed)
        with self.assertRaises(ValueError):
            create_manifest(renamed, self.tag, self.commit, '')

    def test_cli(self):
        notes = self.root / 'notes'
        notes.write_text('发行说明', encoding='utf-8')
        output = self.root / 'ios-update.json'
        process = subprocess.run([
            sys.executable, str(Path(__file__).with_name('create_ios_update_manifest.py')),
            str(self.ipa), '--tag', self.tag, '--commit', self.commit,
            '--notes-file', str(notes), '--output', str(output),
        ], capture_output=True, text=True)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(json.loads(output.read_text(encoding='utf-8')), self.manifest(notes='发行说明'))


if __name__ == '__main__':
    unittest.main()
