/* Pre-included by every PE source: the PE side builds against llvm-mingw's headers, with only Wine's own headers
 * (wine/*.h, rtlsupportapi.h's cxx.h users) from Wine's tree, so supply the few Wine winnt.h extensions they use. */
#pragma once
#ifndef DECLSPEC_EXPORT
#define DECLSPEC_EXPORT
#endif
#ifndef ARRAY_SIZE
#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))
#endif
#define CP_UNIXCP 65010
