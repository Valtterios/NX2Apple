#!/usr/bin/env python3
"""Publish a built game to your game data server's folder, for the app's download (dm/ios/Sources/GameDataSync*.swift, docs/game-data-server.md).

    python3 scripts/publish_gamedata.py ~/Games/TotK --out /srv/games [--ipa ~/Games/TotK/TotK.ipa] [--base-url https://games.example.com] [--copy]

Reads the NSP folder's build (<title ID>_build/, what build_ipa_from_nsp.py --romfs separate leaves) and writes, under --out:
    data/<title ID>/<build>/romfs.img       the game files image, as built (a hard link when --out is on the same volume, else a copy; --copy always copies)
    data/<title ID>/<build>/msl.tar         the shader libraries, an uncompressed ustar of b-<version>/ (for an IPA built with --shaders separate)
    data/<title ID>/<build>/manifest.json   what the app reads: sizes, whole-file and per-chunk SHA-256, the image's identity
    data/<title ID>/manifest.json           the same, as the latest version
    ipa/<title ID>/<build>-<CFBundleVersion>.ipa and source.json (AltStore format), with --ipa and --base-url
The app asks for <server>/<title ID>/<build>/manifest.json, the exact version its romfs.id names, then <server>/<title ID>/manifest.json; set its
server address to <base URL>/data. URLs inside a manifest are relative to it. Serve the folder with HTTP Range support and without compression.
"""
import argparse, hashlib, json, os, plistlib, re, shutil, subprocess, sys, tarfile, zipfile
from datetime import datetime, timezone
from pathlib import Path

CHUNK = 16 << 20   # the app fetches and checks 16 MiB at a time (GameDataSyncCore.swift)
REPO = Path(__file__).resolve().parent.parent


def hashes(path):
    whole, chunks = hashlib.sha256(), []
    with open(path, 'rb') as f:
        while b := f.read(CHUNK):
            whole.update(b); chunks.append(hashlib.sha256(b).hexdigest())
    return whole.hexdigest(), chunks


def part(path, url, **extra):
    sha, chunks = hashes(path)
    return dict(url=url, size=path.stat().st_size, sha256=sha, chunk_size=CHUNK, chunks=chunks, **extra)


def place(src, dst, copy):
    if dst.exists():
        if dst.stat().st_size == src.stat().st_size and (dst.samefile(src) or dst.stat().st_mtime >= src.stat().st_mtime): return
        dst.unlink()
    dst.parent.mkdir(parents=True, exist_ok=True)
    if not copy:
        try: os.link(src, dst); return
        except OSError: pass
    shutil.copyfile(src, dst)


def ustar(src_dir, tar_path, keep=lambda p: True):
    """b-<version>/ and its files, in name order, as plain ustar: no pax headers, no compression (what the app's unpacker reads). keep: which files go in."""
    tmp = tar_path.with_suffix('.tar.tmp')
    with tarfile.open(tmp, 'w', format=tarfile.USTAR_FORMAT) as t:
        def add(p):
            info = t.gettarinfo(str(p), arcname=str(p.relative_to(src_dir.parent)))
            info.uid = info.gid = 0; info.uname = info.gname = ''; info.mtime = 0; info.mode = 0o755 if p.is_dir() else 0o644
            if p.is_dir(): t.addfile(info)
            else:
                with open(p, 'rb') as f: t.addfile(info, f)
        add(src_dir)
        for p in sorted(src_dir.rglob('*')):
            if p.is_dir() or keep(p): add(p)
    tmp.replace(tar_path)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('nsp_dir', type=Path, help='the game\'s NSP folder, holding <title ID>_build/ from build_ipa_from_nsp.py --romfs separate')
    ap.add_argument('--out', type=Path, required=True, help='the server\'s root folder (it gets data/, ipa/ and source.json)')
    ap.add_argument('--ipa', type=Path, help='the IPA to publish beside the data (its romfs.id must name this image)')
    ap.add_argument('--base-url', help='the server\'s public address, e.g. https://games.example.com: needed for source.json')
    ap.add_argument('--copy', action='store_true', help='copy the image instead of hard-linking it')
    ap.add_argument('--with-pull-libs', action='store_true', help='keep the _bp.metallib pulling-vertex libraries, which build_ipa.sh leaves out unless the profile turns pso_mtl4 on (used only when the IPA has no shaders to copy the list from)')
    ap.add_argument('--no-shaders', action='store_true', help='leave the shader libraries out (for apps that carry their own)')
    a = ap.parse_args()

    builds = sorted(a.nsp_dir.expanduser().glob('*_build'))
    if len(builds) != 1: sys.exit(f'expected one <title ID>_build folder in {a.nsp_dir}, found {len(builds)}')
    work = builds[0]; title = work.name.split('_')[0].upper()
    images = sorted((p for p in (work / 'extract').glob('v*/RomFS.img') if re.fullmatch(r'v\d+', p.parent.name)), key=lambda p: int(p.parent.name[1:]))   # not v0.partial/: an extraction cut off
    if not images: sys.exit(f'no RomFS.img in {work}/extract: build with --romfs separate first')
    image = images[-1]; build = image.parent.name
    ipa = (a.ipa or next(iter(sorted(a.nsp_dir.expanduser().glob('*.ipa'))), None))
    expected = info = None; ipa_msl = set()
    if ipa:
        with zipfile.ZipFile(ipa) as z:
            names = z.namelist()
            idn = next((n for n in names if re.fullmatch(r'Payload/[^/]+\.app/romfs\.id', n)), None)
            pl = next((n for n in names if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', n)), None)
            expected = z.read(idn).decode().strip() if idn else None
            info = plistlib.loads(z.read(pl)) if pl else {}
            ipa_msl = {m.group(1) for n in names if (m := re.fullmatch(r'Payload/[^/]+\.app/msl/(b-[^/]+/.+[^/])', n))}
    version = (re.search(r'version=(\S+)', expected).group(1) if expected else None) or (info or {}).get('CFBundleShortVersionString') or build
    identity = subprocess.run([sys.executable, '-I', str(REPO / 'dm/tools/romfs_image.py'), '--identity', str(image), title, version, build],
                              check=True, capture_output=True, text=True).stdout.strip()
    key = lambda s: sorted(t for t in s.split() if t.startswith(('size=', 'index=')))
    if expected and key(expected) != key(identity): sys.exit(f'{ipa.name} needs another image:\n  app:   {expected}\n  image: {identity}\nrebuild the IPA, or publish the matching build')

    dest = a.out / 'data' / title / build
    print(f'{title} {version} ({build}) → {dest}')
    place(image, dest / 'romfs.img', a.copy)
    print(f'  romfs.img  {image.stat().st_size / 1e9:.2f} GB, hashing…')
    manifest = dict(format=1, title=title, name=(info or {}).get('CFBundleDisplayName'), version=version, build=build,
                    published=datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                    romfs=part(dest / 'romfs.img', f'{build}/romfs.img', identity=identity))
    if not a.no_shaders:
        libs = sorted(p for p in (work / 'shader' / 'ios').glob('b-*') if p.is_dir())   # not b-<version>.key, the cache key beside it
        if not libs:   # a Vulkan or OpenGL game: its shaders are one library inside the IPA (build_ipa.sh), nothing to publish
            if not (work / 'shader' / 'ios').exists(): sys.exit(f'no shader libraries in {work}/shader/ios (or pass --no-shaders)')
            print('  shaders    none to publish: this game\'s shader library travels inside its IPA')
    if not a.no_shaders and libs:
        tar = dest / 'msl.tar'
        # the same files the IPA carries: its own list when it has one (a default build), else build_ipa.sh's rule for the pulling-vertex libraries
        rel = lambda p: str(p.relative_to(libs[-1].parent))
        keep = (lambda p: rel(p) in ipa_msl) if ipa_msl else (lambda p: a.with_pull_libs or not p.name.endswith('_bp.metallib'))
        print(f'  msl.tar    {libs[-1].name}, packing{" the IPA\'s " + str(len(ipa_msl)) + " files" if ipa_msl else ""}…'); ustar(libs[-1], tar, keep)
        manifest['shaders'] = part(tar, f'{build}/msl.tar', dir=libs[-1].name)
        if tar.stat().st_size < 1 << 20: sys.exit(f'{tar} is almost empty: {libs[-1]} holds no shader libraries')
        print(f'             {tar.stat().st_size / 1e9:.2f} GB')
    # manifest URLs are relative to the manifest: the per-build copy sits beside its files, the latest one a folder above
    (dest / 'manifest.json').write_text(json.dumps(dict(manifest, romfs=dict(manifest['romfs'], url='romfs.img'),
        **({'shaders': dict(manifest['shaders'], url='msl.tar')} if 'shaders' in manifest else {})), indent=1))
    (dest.parent / 'manifest.json').write_text(json.dumps(manifest, indent=1))
    print(f'  manifests  {dest / "manifest.json"}, {dest.parent / "manifest.json"}')

    if ipa and a.base_url:
        bv = info.get('CFBundleVersion', '0')
        ipa_dst = a.out / 'ipa' / title / f'{build}-{bv}.ipa'; place(ipa, ipa_dst, True)
        icon = image.parent / 'icon.jpg'   # the game's own icon, as the build saved it from the NSP's control data
        icon_url = None
        if icon.exists():
            place(icon, a.out / 'ipa' / title / 'icon.jpg', True)
            icon_url = f'{a.base_url.rstrip("/")}/ipa/{title}/icon.jpg'
        src = a.out / 'source.json'
        s = json.loads(src.read_text()) if src.exists() else dict(name='NX2Apple games', identifier='local.nx2apple.games', apps=[])
        bid = info.get('CFBundleIdentifier', f'org.nxnative.{title.lower()}')
        app = next((x for x in s['apps'] if x.get('bundleIdentifier') == bid), None)
        if not app: app = dict(name=info.get('CFBundleDisplayName', title), bundleIdentifier=bid, developerName='NX2Apple (your build)', localizedDescription=f'Your build of {title}. Game data: {a.base_url.rstrip("/")}/data', versions=[]); s['apps'].append(app)
        if icon_url: app['iconURL'] = icon_url   # the server's index step adds the token, as it does to downloadURL
        app['versions'] = [v for v in app['versions'] if v.get('buildVersion') != bv]
        app['versions'].insert(0, dict(version=info.get('CFBundleShortVersionString', version), buildVersion=bv, date=manifest['published'],
                                       downloadURL=f'{a.base_url.rstrip("/")}/ipa/{title}/{ipa_dst.name}', size=ipa_dst.stat().st_size, minOSVersion=info.get('MinimumOSVersion', '26.0')))
        src.write_text(json.dumps(s, indent=1))
        print(f'  ipa        {ipa_dst} (source.json updated)')
    print(f'done. In the app: Game data server = {(a.base_url or "https://<your server>").rstrip("/")}/data')


if __name__ == '__main__':
    main()
