import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, rm, symlink, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { inspectDMGPayload } from './terminal-dmg-payload.mjs';

const scripts = path.dirname(fileURLToPath(import.meta.url));
const treeGenerator = path.join(scripts, 'artifact-tree-manifest.rb');
const temporary = await mkdtemp(path.join(os.tmpdir(), 'peekaboo-dmg-payload-test.'));
try {
  const root = path.join(temporary, 'volume');
  await mkdir(path.join(root, '.background'), { recursive: true });
  await mkdir(path.join(root, 'Peekaboo.app', 'Contents'), { recursive: true });
  await writeFile(path.join(root, '.DS_Store'), 'finder');
  await writeFile(path.join(root, '.VolumeIcon.icns'), 'icon');
  await writeFile(path.join(root, '.background', 'background.png'), 'background');
  await writeFile(path.join(root, 'Peekaboo.app', 'Contents', 'Info.plist'), 'app');
  await symlink('/Applications', path.join(root, 'Applications'));
  const expectedTree = path.join(temporary, 'app-tree.json');
  const tree = spawnSync('/usr/bin/ruby', [treeGenerator, path.join(root, 'Peekaboo.app')], { encoding: 'utf8' });
  assert.equal(tree.status, 0);
  await writeFile(expectedTree, tree.stdout);

  const metadata = spawnSync('/usr/bin/ruby', [path.join(scripts, 'support/test-fixture-metadata.rb'),
    'inspect', temporary, root], { encoding: 'utf8' });
  assert.equal(metadata.status, 0, metadata.stderr);
  const fixtureMetadata = metadata.stdout.trim();
  assert.ok(['clean', 'persistent-provenance'].includes(fixtureMetadata));

  await writeFile(path.join(root, 'unexpected'), 'unexpected');
  await assert.rejects(inspectDMGPayload({ mountedRoot: root, expectedAppTree: expectedTree, treeGenerator }),
    /root entries differ/);
  await rm(path.join(root, 'unexpected'));
  process.stdout.write('test-terminal-dmg-payload: PASS root-entry rejection\n');
  if (fixtureMetadata === 'clean') {
    const receipt = await inspectDMGPayload({ mountedRoot: root, expectedAppTree: expectedTree, treeGenerator });
    assert.equal(receipt.version, 1);
    assert.equal(receipt.applications_symlink, '/Applications');
    assert.equal(receipt.metadata.length, 2);

    assert.equal(spawnSync('/usr/bin/xattr', ['-w', 'com.openclaw.peekaboo.fixture', 'value',
      path.join(root, '.VolumeIcon.icns')]).status, 0);
    await assert.rejects(inspectDMGPayload({ mountedRoot: root, expectedAppTree: expectedTree, treeGenerator }),
      /unbound xattrs/);
    assert.equal(spawnSync('/usr/bin/xattr', ['-d', 'com.openclaw.peekaboo.fixture',
      path.join(root, '.VolumeIcon.icns')]).status, 0);
    assert.equal(spawnSync('/usr/bin/xattr', ['-s', '-w', 'com.openclaw.peekaboo.fixture', 'value',
      path.join(root, 'Applications')]).status, 0);
    await assert.rejects(inspectDMGPayload({ mountedRoot: root, expectedAppTree: expectedTree, treeGenerator }),
      /Applications contains unbound xattrs/);
    assert.equal(spawnSync('/usr/bin/xattr', ['-s', '-d', 'com.openclaw.peekaboo.fixture',
      path.join(root, 'Applications')]).status, 0);
    await writeFile(path.join(root, 'Peekaboo.app', 'Contents', 'Info.plist'), 'changed');
    await assert.rejects(inspectDMGPayload({ mountedRoot: root, expectedAppTree: expectedTree, treeGenerator }),
      /differs from notarized app tree/);
    process.stdout.write('test-terminal-dmg-payload: PASS 4 native positive/isolated mutation cases\n');
  } else {
    await assert.rejects(inspectDMGPayload({ mountedRoot: root, expectedAppTree: expectedTree, treeGenerator }),
      /^Error: DMG payload(?:\/[^\n]*)? contains unbound xattrs$/);
    process.stdout.write('test-terminal-dmg-payload: PASS strict production rejection of persistent provenance\n');
    process.stdout.write('test-terminal-dmg-payload: SKIP 4 cases: native positive receipt, isolated file/symlink ' +
      'xattrs, app-tree mutation; fixture contains only com.apple.provenance (11 bytes); no native positive DMG proof\n');
  }
} finally {
  await rm(temporary, { recursive: true, force: true });
}

process.stdout.write('test-terminal-dmg-payload: ok (executed cases passed; unavailable cases marked SKIP above)\n');
