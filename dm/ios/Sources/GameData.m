// The C side of the game data download (GameData.h).
#import "GameData.h"
#include "hle_profile.h"
#include "romfs_identity.h"
#include "../../gfx/nvn/dmsh_chain.h"   // DMSH_CHAIN, the version the host's shader loader looks for (nvn_mtl.m shmap_load)

NSString *dm_game_title(void) { return @(dm_profile()->id); }

NSString *dm_game_dir(void) {
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    return [[doc stringByAppendingPathComponent:@"games"] stringByAppendingPathComponent:dm_game_title()];
}

static NSString *bundle_romfs_id(void) { return [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"romfs.id"]; }

NSString *dm_expected_romfs_identity(void) {
    NSString *s = [NSString stringWithContentsOfFile:bundle_romfs_id() encoding:NSUTF8StringEncoding error:nil];
    s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return s.length ? s : nil;
}

int dm_romfs_status(NSString *path) {
    romfs_id want, got;
    switch (romfs_id_check(bundle_romfs_id().fileSystemRepresentation, path.fileSystemRepresentation, &want, &got)) {
    case ROMFS_ID_OK: return 0;
    case ROMFS_ID_NONE: { romfs_id any; return romfs_id_of_image(path.fileSystemRepresentation, &any) ? 0 : (errno == ENOENT ? 1 : 2); }
    case ROMFS_ID_MISSING: return 1;
    case ROMFS_ID_UNREADABLE: return 2;
    case ROMFS_ID_DIFFERENT: return 3;
    default: return -1;
    }
}

NSString *dm_shader_dir_name(void) { return @"b-" DMSH_CHAIN; }

BOOL dm_have_shaders(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *own = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"msl"];   // the app's own: b-<version> for an NVN game, vk/ or gl/ for the others
    NSString *dl = [[dm_game_dir() stringByAppendingPathComponent:@"msl"] stringByAppendingPathComponent:dm_shader_dir_name()];
    NSString *tar = [dm_game_dir() stringByAppendingPathComponent:@"msl.tar"];   // read in place by the host (nvn_mtl.m msl_pack_open)
    return [fm fileExistsAtPath:own] || [fm fileExistsAtPath:dl] || [fm fileExistsAtPath:tar];
}
