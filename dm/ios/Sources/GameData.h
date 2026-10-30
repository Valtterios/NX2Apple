// What the game data download (GameDataSync.swift) needs to know about this build, from the C side.
//
// The downloader puts a game's data into the per-game layout main.m already reads,
// Documents/games/<title ID>/{romfs.img, msl/}, and checks the image against the identity the build
// carries (<App>/romfs.id, dm/host/romfs_identity.h): the same check main.m makes before it uses an
// image, so a download is complete exactly when the game would accept it.

#import <Foundation/Foundation.h>

/// The game's title ID (the runtime profile's), e.g. 0100F2C0115B6000.
NSString *dm_game_title(void);

/// Documents/games/<title ID>: where downloaded game data goes (main.m game_dir_for).
NSString *dm_game_dir(void);

/// The identity line of the image this build needs (<App>/romfs.id), or nil for a build that takes any image.
NSString *dm_expected_romfs_identity(void);

/// How the image at path compares with this build's identity: 0 matches (or the build takes any complete image),
/// 1 missing, 2 cut off or not an image, 3 another version, -1 the build's own identity cannot be read.
int dm_romfs_status(NSString *path);

/// The shader library folder this build loads ("b-<translation chain version>", dm/gfx/nvn/dmsh_chain.h).
NSString *dm_shader_dir_name(void);

/// YES when the app has shader libraries to run with: its own <App>/msl, or a downloaded games/<title ID>/msl/b-<version>.
BOOL dm_have_shaders(void);
