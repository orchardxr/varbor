cmake_minimum_required(VERSION 3.20)
project(mvt_test C)

if(NOT TARGET mvt)
    add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../encoder ${CMAKE_CURRENT_BINARY_DIR}/mvt)
endif()

add_executable(mvt_test mvt_test.c)
target_compile_options(mvt_test PRIVATE -Wall -Wextra -Wno-unused-parameter)
target_link_libraries(mvt_test PRIVATE mvt m)
