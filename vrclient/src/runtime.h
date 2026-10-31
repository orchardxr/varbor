/* Where the unix side finds the native OpenVR runtime (OpenComposite's vrclient.dylib). No Wine or Windows headers:
 * macos_unix.cpp and tests/runtime_test.cpp include it. */
#pragma once
#include <string>
#include <vector>
#include <unistd.h>

/* The standard OpenComposite for macOS install, the one WiVRn registers while its server runs. */
static inline std::string varbor_opencomposite_install( const std::string &home )
{
    return home + "/Library/Application Support/OpenComposite/runtime";
}

/* A runtime directory (or the dylib itself) -> its readable vrclient.dylib. */
static inline bool varbor_runtime_dylib( const std::string &dir, std::string &out )
{
    static const char *const candidates[] = {"/bin/osx64/vrclient.dylib", "/bin/vrclient.dylib", "/vrclient.dylib"};
    if (dir.empty()) return false;
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

enum varbor_runtime_source
{
    VARBOR_RUNTIME_NONE,
    VARBOR_RUNTIME_ENV,
    VARBOR_RUNTIME_GIVEN,
    VARBOR_RUNTIME_VRPATH,
    VARBOR_RUNTIME_INSTALL,
};

/* VARBOR_VRCLIENT_RUNTIME, then PROTON_VR_RUNTIME (given by the PE side), then the first runtime in the macOS
 * openvrpaths.vrpath with a vrclient.dylib. WiVRn writes that file only while its server runs, so last comes the
 * standard install: a game started before WiVRn still loads OpenComposite, which then fails VR_Init the way an
 * unregistered runtime does on Linux (no OpenXR runtime) and can retry later. */
static inline enum varbor_runtime_source varbor_pick_runtime( const char *env, const char *given,
                                                             const std::vector<std::string> &registered,
                                                             const std::string &home, std::string &out )
{
    if (env && varbor_runtime_dylib( env, out )) return VARBOR_RUNTIME_ENV;
    if (given && varbor_runtime_dylib( given, out )) return VARBOR_RUNTIME_GIVEN;
    for (const std::string &r : registered)
        if (varbor_runtime_dylib( r, out )) return VARBOR_RUNTIME_VRPATH;
    if (!home.empty() && varbor_runtime_dylib( varbor_opencomposite_install( home ), out )) return VARBOR_RUNTIME_INSTALL;
    out.clear();
    return VARBOR_RUNTIME_NONE;
}
