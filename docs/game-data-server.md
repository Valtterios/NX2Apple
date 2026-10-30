# Game data server

An iPhone app built with `--romfs separate` can download its game data from your own server, instead of copying it over USB or the Files app. Its launcher has a **Game data server** section: enter the server address and access token, then press **Download game data**. The download resumes after an interruption, checks every piece, and an update fetches only what changed. **Delete game data** frees the space and keeps your saves.

## What the server holds

```
/data/<title ID>/<build>/romfs.img       the game files image, exactly as built
/data/<title ID>/<build>/msl.tar         the shader libraries (plain ustar, uncompressed), for an IPA built with --shaders separate
/data/<title ID>/<build>/manifest.json   sizes, SHA-256 per 16 MiB chunk, the image's identity
/data/<title ID>/manifest.json           the latest version
/ipa/<title ID>/<build>-<CFBundleVersion>.ipa
/source.json                             AltStore-format source
```

The app's server setting is `<server>/data`. It asks for `/data/<title ID>/<build>/manifest.json`, the exact version its `romfs.id` names, and then for `/data/<title ID>/manifest.json`. URLs inside a manifest are relative to the manifest. Every request carries `Authorization: Bearer <token>`.

The server must answer Range requests with 206, and must not compress `/data` or `/ipa`. Any static file server does this, for example Caddy `file_server` or nginx with gzip off.

## Publishing a game

```bash
python3 scripts/build_ipa_from_nsp.py ~/Games/TotK -k ~/Games/TotK/prod.keys --romfs separate [--shaders separate]
python3 scripts/publish_gamedata.py ~/Games/TotK --out ~/Games/server-staging --ipa ~/Games/TotK/TotK.ipa --base-url https://games.example.com
rsync -a --partial --inplace -P ~/Games/server-staging/ user@server:/srv/games/
```

`publish_gamedata.py` checks that the IPA's `romfs.id` names this image before it writes anything. On the same volume the image is hard-linked rather than copied. Don't repack or recompress `romfs.img` on the server: the manifest's chunk hashes are of the file as built.

`--shaders separate` leaves the 1–1.5 GB of shader libraries out of the IPA, so the IPA is about 100 MB, and the app downloads them with the game data. An IPA without its shaders can't start until that download is done.

## Manifest

```json
{
 "format": 1, "title": "0100F2C0115B6000", "name": "…", "version": "1.4.3", "build": "v720896", "published": "2026-10-30T10:00:00Z",
 "romfs":   {"url": "romfs.img", "size": 17046402254, "sha256": "…", "chunk_size": 16777216, "chunks": ["…"], "identity": "DMROMFSID1 title=… size=… index=…"},
 "shaders": {"url": "msl.tar",   "size": 1530000000,  "sha256": "…", "chunk_size": 16777216, "chunks": ["…"], "dir": "b-373efc7add5f"}
}
```

`identity` must name the same image as the app's `romfs.id` (its `size` and `index`). That is how the app tells "this version" from "update needed". `shaders.dir` must be the app's translation chain version.

## On the phone

Downloads go to `Documents/games/<title ID>/` in the app's data folder (`romfs.img`, `msl/`). That folder is the one `main.m` reads first, after any location picked under **Game data**. The first time the app uses that folder, it copies the saves from `Documents/save` into `games/<title ID>/save`. Keep the app open while it downloads: iOS pauses it in the background, and the next **Download** resumes where it stopped.
