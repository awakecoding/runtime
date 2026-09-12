if (NOT CLR_CMAKE_TARGET_WIN32)
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
