/* Finds the native OpenVR runtime (OpenComposite's vrclient.dylib), the macOS counterpart of Proton's
 * <runtime>/bin/linux64/vrclient.so. */
#include <stdarg.h>
#include <stddef.h>

#include "ntstatus.h"
#define WIN32_NO_STATUS
#include "windef.h"
#include "winbase.h"

#include <string>
#include <fstream>
#include <sstream>
#include "json/json.h"

#include "unix_private.h"
#include "runtime.h"

#include <stdlib.h>
#include <unistd.h>
#include <pwd.h>
#include <sys/stat.h>
#include <time.h>
#include <mach-o/dyld.h>

#if 0
#pragma makedep unix
#endif

WINE_DEFAULT_DEBUG_CHANNEL(vrclient);

static std::string runtime_path;

static std::string home_dir(void);

/* One line to ~/Library/Logs/VarboR/bridge.log, whatever VRCLIENT_LOG says: confirms which path a game took. */
extern "C" void varbor_note( const char *msg )
{
    std::string dir = home_dir() + "/Library/Logs/VarboR";
    char exe[1024] = "?", when[32];
    uint32_t size = sizeof(exe);
    time_t now = time( NULL );
    FILE *f;

    mkdir( dir.c_str(), 0755 );
    if (!(f = fopen( (dir + "/bridge.log").c_str(), "a" ))) return;
    if (_NSGetExecutablePath( exe, &size )) exe[0] = 0;
    strftime( when, sizeof(when), "%Y-%m-%dT%H:%M:%S%z", localtime( &now ) );
    fprintf( f, "%s pid %d %s: vrclient: %s\n", when, (int)getpid(), strrchr( exe, '/' ) ? strrchr( exe, '/' ) + 1 : exe, msg );
    fclose( f );
}

static std::string home_dir(void)
{
    const char *home = getenv( "HOME" );
    struct passwd *pw;
    if (home && *home) return home;
    return (pw = getpwuid( getuid() )) ? pw->pw_dir : "";
}

/* The runtimes in the macOS OpenVR paths file, as SteamVR for macOS kept it (WiVRn writes it while its server runs). */
static std::vector<std::string> vrpath_runtimes(void)
{
    std::string file = home_dir() + "/Library/Application Support/OpenVR/.openvr/openvrpaths.vrpath";
    std::ifstream in( file );
    std::stringstream text;
    Json::Reader reader;
    Json::Value root;
    std::vector<std::string> out;

    if (!in) return out;
    text << in.rdbuf();
    if (!reader.parse( text.str(), root ) || !root["runtime"].isArray())
    {
        ERR( "%s: no runtime array.\n", file.c_str() );
        return out;
    }
    for (const Json::Value &v : root["runtime"])
        if (v.isString()) out.push_back( v.asString() );
    return out;
}

extern "C" const char *varbor_find_runtime( const char *given )
{
    std::string found;

    switch (varbor_pick_runtime( getenv( "VARBOR_VRCLIENT_RUNTIME" ), given, vrpath_runtimes(), home_dir(), found ))
    {
    case VARBOR_RUNTIME_NONE:
        runtime_path.clear();
        return NULL;
    case VARBOR_RUNTIME_INSTALL:
        varbor_note( "runtime: OpenComposite's install, none registered in openvrpaths.vrpath (WiVRn not running yet?)" );
        break;
    default:
        break;
    }
    runtime_path = found;
    return runtime_path.c_str();
}

NTSTATUS varbor_runtime_info( void *args )
{
    struct varbor_runtime_info_params *params = (struct varbor_runtime_info_params *)args;
    snprintf( params->path, sizeof(params->path), "%s", runtime_path.c_str() );
    return 0;
}
