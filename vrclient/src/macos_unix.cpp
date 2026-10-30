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

#include <stdlib.h>
#include <unistd.h>
#include <pwd.h>

#if 0
#pragma makedep unix
#endif

WINE_DEFAULT_DEBUG_CHANNEL(vrclient);

static std::string runtime_path;

static bool runtime_dylib( const std::string &dir, std::string &out )
{
    static const char *const candidates[] = {"/bin/osx64/vrclient.dylib", "/bin/vrclient.dylib", "/vrclient.dylib"};
    if (dir.size() > 6 && !dir.compare( dir.size() - 6, 6, ".dylib" ))
    {
        if (access( dir.c_str(), R_OK )) return false;
        out = dir;
        return true;
    }
    for (const char *c : candidates)
    {
        std::string path = dir + c;
        if (!access( path.c_str(), R_OK ))
        {
            out = path;
            return true;
        }
    }
    return false;
}

static std::string home_dir(void)
{
    const char *home = getenv( "HOME" );
    struct passwd *pw;
    if (home && *home) return home;
    return (pw = getpwuid( getuid() )) ? pw->pw_dir : "";
}

/* The macOS OpenVR paths file, as SteamVR for macOS kept it. */
static bool runtime_from_vrpath( std::string &out )
{
    std::string file = home_dir() + "/Library/Application Support/OpenVR/.openvr/openvrpaths.vrpath";
    std::ifstream in( file );
    std::stringstream text;
    Json::Reader reader;
    Json::Value root;

    if (!in) return false;
    text << in.rdbuf();
    if (!reader.parse( text.str(), root ) || !root["runtime"].isArray())
    {
        ERR( "%s: no runtime array.\n", file.c_str() );
        return false;
    }
    for (const Json::Value &v : root["runtime"])
        if (v.isString() && runtime_dylib( v.asString(), out )) return true;
    return false;
}

/* MACVR_VRCLIENT_RUNTIME (a runtime directory or the dylib itself), then the path the PE side got from
 * PROTON_VR_RUNTIME, then the macOS openvrpaths.vrpath. */
extern "C" const char *macvr_find_runtime( const char *given )
{
    const char *env = getenv( "MACVR_VRCLIENT_RUNTIME" );
    std::string found;

    if (env && *env && runtime_dylib( env, found )) runtime_path = found;
    else if (given && *given && runtime_dylib( given, found )) runtime_path = found;
    else if (runtime_from_vrpath( found )) runtime_path = found;
    else
    {
        runtime_path.clear();
        return NULL;
    }
    return runtime_path.c_str();
}

NTSTATUS macvr_runtime_info( void *args )
{
    struct macvr_runtime_info_params *params = (struct macvr_runtime_info_params *)args;
    snprintf( params->path, sizeof(params->path), "%s", runtime_path.c_str() );
    return 0;
}
