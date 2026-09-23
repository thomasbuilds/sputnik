cmake_minimum_required(VERSION 3.22)
project(nostr_secp256k1_android LANGUAGES C)

set(VENDOR_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../src")

set(BUILD_SHARED_LIBS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(SECP256K1_BUILD_BENCHMARK OFF CACHE BOOL "" FORCE)
set(SECP256K1_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(SECP256K1_BUILD_EXHAUSTIVE_TESTS OFF CACHE BOOL "" FORCE)
set(SECP256K1_BUILD_CTIME_TESTS OFF CACHE BOOL "" FORCE)
set(SECP256K1_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(SECP256K1_INSTALL OFF CACHE BOOL "" FORCE)
set(SECP256K1_ENABLE_MODULE_ECDH OFF CACHE BOOL "" FORCE)
set(SECP256K1_ENABLE_MODULE_RECOVERY OFF CACHE BOOL "" FORCE)
set(SECP256K1_ENABLE_MODULE_EXTRAKEYS ON CACHE BOOL "" FORCE)
set(SECP256K1_ENABLE_MODULE_SCHNORRSIG ON CACHE BOOL "" FORCE)
set(SECP256K1_ENABLE_MODULE_MUSIG OFF CACHE BOOL "" FORCE)
set(SECP256K1_ENABLE_MODULE_ELLSWIFT OFF CACHE BOOL "" FORCE)
set(SECP256K1_ENABLE_MODULE_SILENTPAYMENTS OFF CACHE BOOL "" FORCE)
add_subdirectory("${VENDOR_ROOT}/secp256k1" secp256k1)

add_library(nostr_secp256k1 SHARED "${VENDOR_ROOT}/nostr_secp256k1.c")
target_link_libraries(nostr_secp256k1 PRIVATE secp256k1)
target_compile_options(nostr_secp256k1 PRIVATE -Wall -Wextra -Werror)
# Keep the statically linked libsecp256k1 API out of the dynamic symbol table:
# only the nostr_* entry points are exported, and the shim's calls into
# libsecp256k1 bind at link time, so no other library can interpose them.
target_link_options(nostr_secp256k1 PRIVATE "LINKER:--exclude-libs,ALL")
