# Included by the build hook (CMAKE_PROJECT_zt_INCLUDE) when the memory_guard user define is set: once
# libzt's CMakeLists.txt has defined its targets, the shared library gets the guarded allocator
# (zt_guard.c) and the linker sends libzt's allocation calls to it.
set(ZT_GUARD_SOURCE "${CMAKE_CURRENT_LIST_DIR}/zt_guard.c" CACHE INTERNAL "")

function(zt_guard_attach)
  target_sources(zt-shared PRIVATE "${ZT_GUARD_SOURCE}")
  target_link_options(zt-shared PRIVATE
    "LINKER:--wrap=malloc,--wrap=free,--wrap=calloc,--wrap=realloc"
    "LINKER:--wrap=posix_memalign,--wrap=memalign,--wrap=aligned_alloc,--wrap=malloc_usable_size")
endfunction()

cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL zt_guard_attach)
