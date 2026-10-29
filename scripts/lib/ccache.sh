# Compile CMake builds through ccache when it is installed (CI sets these itself). Source from bash.
# Content-keyed, so the fresh mtimes patches.sh apply leaves still hit. Takes effect at a build dir's next configure.
if command -v ccache > /dev/null; then
	for l in C CXX OBJC OBJCXX; do
		v="CMAKE_${l}_COMPILER_LAUNCHER"
		export "$v=${!v:-ccache}"
	done
	export CCACHE_SLOPPINESS="${CCACHE_SLOPPINESS:-include_file_mtime,include_file_ctime,time_macros,pch_defines}"
	export CCACHE_COMPILERCHECK="${CCACHE_COMPILERCHECK:-content}"
fi
