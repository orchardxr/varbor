#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include "runtime.h"

static int failures;

static void expect( bool ok, const char *what )
{
    if (ok) return;
    printf( "FAIL: %s\n", what );
    failures++;
}

static std::string make_runtime( const std::string &dir )
{
    std::string path;
    for (size_t i = 1; (i = dir.find( '/', i )) != std::string::npos; i++) mkdir( dir.substr( 0, i ).c_str(), 0755 );
    mkdir( dir.c_str(), 0755 );
    mkdir( (dir + "/bin").c_str(), 0755 );
    mkdir( (dir + "/bin/osx64").c_str(), 0755 );
    path = dir + "/bin/osx64/vrclient.dylib";
    if (FILE *f = fopen( path.c_str(), "w" )) fclose( f );
    return path;
}

int main(void)
{
    char tmpl[] = "/tmp/varbor-runtime-test.XXXXXX";
    std::string home = mkdtemp( tmpl ), out;
    std::string install = varbor_opencomposite_install( home ) + "/bin/osx64/vrclient.dylib";
    std::string other = make_runtime( home + "/other" );

    expect( varbor_pick_runtime( NULL, NULL, {}, home, out ) == VARBOR_RUNTIME_NONE && out.empty(), "nothing installed" );
    expect( varbor_pick_runtime( NULL, NULL, {home + "/gone"}, home, out ) == VARBOR_RUNTIME_NONE, "registered runtime without a dylib" );

    make_runtime( varbor_opencomposite_install( home ) );
    expect( varbor_pick_runtime( NULL, NULL, {}, home, out ) == VARBOR_RUNTIME_INSTALL && out == install,
            "no vrpath runtime: the standard install" );
    expect( varbor_pick_runtime( NULL, "", {home + "/gone"}, home, out ) == VARBOR_RUNTIME_INSTALL && out == install,
            "only stale vrpath runtimes: the standard install" );
    expect( varbor_pick_runtime( NULL, NULL, {home + "/gone", home + "/other"}, home, out ) == VARBOR_RUNTIME_VRPATH && out == other,
            "a registered runtime wins over the install" );
    expect( varbor_pick_runtime( NULL, (home + "/other").c_str(), {}, home, out ) == VARBOR_RUNTIME_GIVEN && out == other,
            "PROTON_VR_RUNTIME" );
    expect( varbor_pick_runtime( other.c_str(), NULL, {varbor_opencomposite_install( home )}, home, out ) == VARBOR_RUNTIME_ENV && out == other,
            "VARBOR_VRCLIENT_RUNTIME as the dylib" );
    expect( varbor_pick_runtime( "", NULL, {}, home, out ) == VARBOR_RUNTIME_INSTALL, "empty VARBOR_VRCLIENT_RUNTIME" );
    expect( varbor_pick_runtime( NULL, NULL, {}, "", out ) == VARBOR_RUNTIME_NONE, "no home" );

    system( ("rm -rf '" + home + "'").c_str() );
    if (failures) return 1;
    puts( "runtime_test: ok" );
    return 0;
}
