if (NOT CLR_CMAKE_TARGET_WIN32 OR
    (NOT CLR_CMAKE_TARGET_ARCH_AMD64 AND
     NOT CLR_CMAKE_TARGET_ARCH_ARM64 AND
     NOT CLR_CMAKE_TARGET_ARCH_I386))
  return()
endif()

if (CLR_CMAKE_TARGET_ARCH_AMD64)
  set(AOTCRTSTUB_ARCH_SOURCES aotcrtstub_amd64.asm)
  set(NTDLLCRT_DEF ntdllcrt.def)
  set(NTDLLCRT_MACHINE X64)
elseif (CLR_CMAKE_TARGET_ARCH_ARM64)
  set(AOTCRTSTUB_ARCH_SOURCES aotcrtstub_arm64.asm)
  set(NTDLLCRT_DEF ntdllcrt.def)
  set(NTDLLCRT_MACHINE ARM64)
else()
  set(AOTCRTSTUB_ARCH_SOURCES aotcrtstub_i386.asm)
  set(AOTCRTSTUB_ARCH_OPTIONS /safeseh)
  set(NTDLLCRT_DEF ntdllcrt_i386.def)
  set(NTDLLCRT_MACHINE X86)
endif()

add_library(aotcrtstub STATIC
  aotcrtstub.c
  aotcrtstubcpp.cpp
  ${AOTCRTSTUB_ARCH_SOURCES})

set_target_properties(aotcrtstub PROPERTIES
  INTERPROCEDURAL_OPTIMIZATION OFF)

target_compile_options(aotcrtstub PRIVATE
  $<$<COMPILE_LANGUAGE:C>:/GS- /Gs1000000 /std:c11 /Zl>
  $<$<COMPILE_LANGUAGE:CXX>:/EHs-c- /GR- /GS- /Gs1000000 /Zl>
  $<$<COMPILE_LANGUAGE:ASM_MASM>:${AOTCRTSTUB_ARCH_OPTIONS}>)

install_static_library(aotcrtstub aotsdk nativeaot)

set(NTDLLCRT_LIBRARY "${CMAKE_CURRENT_BINARY_DIR}/ntdllcrt.lib")
add_custom_command(
  OUTPUT "${NTDLLCRT_LIBRARY}"
  COMMAND "${CMAKE_AR}" /nologo "/DEF:${CMAKE_CURRENT_SOURCE_DIR}/${NTDLLCRT_DEF}" /MACHINE:${NTDLLCRT_MACHINE} "/OUT:${NTDLLCRT_LIBRARY}"
  DEPENDS "${NTDLLCRT_DEF}"
  VERBATIM)

add_custom_target(ntdllcrt DEPENDS "${NTDLLCRT_LIBRARY}")
add_dependencies(aotcrtstub ntdllcrt)
install(FILES "${NTDLLCRT_LIBRARY}" DESTINATION . COMPONENT nativeaot)
