import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import zipfile


REPOSITORY = 'wm0104/CyShineMusic-iOS'
IPA_NAME = 'CyShineMusic-unsigned.ipa'
APP_PLIST = 'Payload/Runner.app/Info.plist'
WIDGET_PLIST = 'Payload/Runner.app/PlugIns/CyShineMusicWidget.appex/Info.plist'


def create_manifest(ipa, tag, commit, notes):
    if not re.fullmatch(r'ios-v[0-9]+\.[0-9]+\.[0-9]+', tag):
        raise ValueError('Invalid iOS release tag')
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Source commit must be a full lowercase SHA')
    ipa = Path(ipa)
    if ipa.name != IPA_NAME:
        raise ValueError('Unexpected IPA filename')
    try:
        with zipfile.ZipFile(ipa) as archive:
            names = archive.namelist()
            if len(names) != len(set(names)):
                raise ValueError('IPA contains duplicate ZIP entries')
            if archive.testzip() is not None:
                raise ValueError('IPA ZIP CRC verification failed')
            app = plistlib.loads(archive.read(APP_PLIST))
            widget = plistlib.loads(archive.read(WIDGET_PLIST))
    except (KeyError, zipfile.BadZipFile, RuntimeError, plistlib.InvalidFileException,
            EOFError, TypeError, OverflowError) as error:
        raise ValueError('IPA or required Info.plist is unreadable') from error
    for bundle, bundle_id in ((app, 'com.cyshine.music'),
                              (widget, 'com.cyshine.music.widget')):
        if not isinstance(bundle, dict) or bundle.get('CFBundleIdentifier') != bundle_id:
            raise ValueError('Unexpected bundle identifier')
        version = bundle.get('CFBundleShortVersionString')
        build = bundle.get('CFBundleVersion')
        if not isinstance(version, str) or version != tag.removeprefix('ios-v'):
            raise ValueError('Bundle version does not match release tag')
        if not isinstance(build, str) or not re.fullmatch(r'[1-9][0-9]*', build):
            raise ValueError('Bundle build must be a positive integer string')
    if app['CFBundleVersion'] != widget['CFBundleVersion']:
        raise ValueError('Widget build does not match main app')
    digest = hashlib.sha256()
    with ipa.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    base = f'https://github.com/{REPOSITORY}/releases'
    return {
        'schema': 1,
        'repository': REPOSITORY,
        'version': app['CFBundleShortVersionString'],
        'build': int(app['CFBundleVersion']),
        'tag': tag,
        'page_url': f'{base}/tag/{tag}',
        'name': app['CFBundleShortVersionString'],
        'notes': notes[:16384],
        'source_commit': commit,
        'ipa': {
            'name': IPA_NAME,
            'url': f'{base}/download/{tag}/{IPA_NAME}',
            'sha256': digest.hexdigest(),
        },
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--notes-file', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        manifest = create_manifest(args.ipa, args.tag, args.commit,
                                   args.notes_file.read_text(encoding='utf-8'))
        args.output.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n',
                               encoding='utf-8')
    except (ValueError, OSError) as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
