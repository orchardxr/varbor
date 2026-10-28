cmake_minimum_required(VERSION 3.20)
project(mvt C OBJC)

add_library(mvt STATIC src/mvt.c src/mvt_metal.m)
target_include_directories(mvt PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_compile_features(mvt PRIVATE c_std_11)
target_compile_options(mvt PRIVATE -Wall -Wextra -Wno-unused-parameter)
target_link_libraries(mvt PUBLIC
    "-framework VideoToolbox"
    "-framework CoreMedia"
    "-framework CoreVideo"
    "-framework CoreFoundation"
    "-framework IOSurface"
    "-framework Metal"
    "-framework Foundation")
