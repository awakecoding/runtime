if (NOT CLR_CMAKE_TARGET_WIN32 OR NOT CLR_CMAKE_TARGET_ARCH_AMD64)
  return()
endif()

add_library(aotcrtstub STATIC
  aotcrtstub.c
  aotcrtstubcpp.cpp
  aotcrtstub_amd64.asm)

set_target_properties(aotcrtstub PROPERTIES
  INTERPROCEDURAL_OPTIMIZATION OFF)

target_compile_options(aotcrtstub PRIVATE
  $<$<COMPILE_LANGUAGE:C>:/GS- /Gs1000000 /std:c11>
  $<$<COMPILE_LANGUAGE:CXX>:/EHs-c- /GR- /GS- /Gs1000000>)

install_static_library(aotcrtstub aotsdk nativeaot)

set(NTDLLCRT_LIBRARY "${CMAKE_CURRENT_BINARY_DIR}/ntdllcrt.lib")
add_custom_command(
  OUTPUT "${NTDLLCRT_LIBRARY}"
  COMMAND "${CMAKE_AR}" /nologo /DEF:"${CMAKE_CURRENT_SOURCE_DIR}/ntdllcrt.def" /MACHINE:X64 /OUT:"${NTDLLCRT_LIBRARY}"
  DEPENDS ntdllcrt.def
  VERBATIM)

add_custom_target(ntdllcrt DEPENDS "${NTDLLCRT_LIBRARY}")
add_dependencies(aotcrtstub ntdllcrt)
install(FILES "${NTDLLCRT_LIBRARY}" DESTINATION . COMPONENT nativeaot)
