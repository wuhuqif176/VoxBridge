cmake_minimum_required(VERSION 3.5.0)
project(HarmonyMic)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH})

# DeepFilterNet3 static library (built by tools/build_libdf.ps1)
add_library(df STATIC IMPORTED)
set_target_properties(df PROPERTIES
    IMPORTED_LOCATION ${NATIVERENDER_ROOT_PATH}/../../../libs/arm64-v8a/libdf.a)

add_library(audio_nr SHARED audio_nr.cpp)

target_link_libraries(audio_nr PUBLIC
    libace_napi.z.so
    df
    libhilog_ndk.z.so
)
