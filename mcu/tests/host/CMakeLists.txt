cmake_minimum_required(VERSION 3.22)
project(chromatic_firmware_host_tests C)
set(CMAKE_C_STANDARD 11)
set(FW_ROOT "${CMAKE_CURRENT_LIST_DIR}/../..")
set(LV_ROOT "${FW_ROOT}/managed_components/lvgl__lvgl")
file(GLOB_RECURSE LV_SOURCES "${LV_ROOT}/src/*.c")
add_library(lvgl_host STATIC ${LV_SOURCES})
target_compile_definitions(lvgl_host PUBLIC LV_CONF_SKIP LV_COLOR_DEPTH=16 LV_MEM_SIZE=262144 LV_LVGL_H_INCLUDE_SIMPLE "CONFIG_CHROMATIC_FW_VER_STR=\"1.0.0 (4.2)\"")
target_include_directories(lvgl_host PUBLIC "${LV_ROOT}" "stubs")
set(FW_INCLUDES main components/common components/dlist components/button components/settings components/mutex components/osd components/osd/system components/osd/status components/menu_mgr components/tab)
foreach(DIR ${FW_INCLUDES})
  target_include_directories(lvgl_host PUBLIC "${FW_ROOT}/${DIR}")
endforeach()
add_executable(osd_test osd_test.c
  "${FW_ROOT}/components/osd/system/rom_browser_ui.c"
  "${FW_ROOT}/components/osd/system/cart_backup_ui.c"
  "${FW_ROOT}/components/osd/status/fw.c"
  "${FW_ROOT}/components/menu_mgr/menu_mgr.c"
  "${FW_ROOT}/components/common/osd_shared.c"
  "${FW_ROOT}/components/fonts/fingfai.c"
  "${FW_ROOT}/components/fonts/jf_dot_k14.c"
  "${FW_ROOT}/components/images/menu_system.c"
  "${FW_ROOT}/components/images/menu_backups_accent.c"
  "${FW_ROOT}/components/images/menu_status.c"
  "${FW_ROOT}/components/images/img_chromatic.c"
  "${FW_ROOT}/components/images/img_magician_hat.c"
  "${FW_ROOT}/components/images/img_magician_wand.c")
target_link_libraries(osd_test PRIVATE lvgl_host m)
add_executable(pc_mode_test pc_mode_test.c "${FW_ROOT}/components/osd/system/pc_backup_mode.c")
target_compile_options(pc_mode_test PRIVATE -ffunction-sections -fdata-sections)
target_link_options(pc_mode_test PRIVATE -Wl,--gc-sections)
target_link_libraries(pc_mode_test PRIVATE lvgl_host m)
enable_testing()
add_test(NAME backups_menu COMMAND osd_test)
add_executable(rom_browser_test rom_browser_test.c "${FW_ROOT}/main/rom_browser.c")
target_compile_definitions(rom_browser_test PRIVATE ROM_BROWSER_ROOT="${CMAKE_CURRENT_BINARY_DIR}/rom-browser-fixture")
target_link_libraries(rom_browser_test PRIVATE lvgl_host m)
add_test(NAME backup_folders COMMAND rom_browser_test)
add_test(NAME pc_mode_lifecycle COMMAND pc_mode_test)
find_package(Python3 COMPONENTS Interpreter REQUIRED)
add_test(NAME qspi_input_timing COMMAND "${Python3_EXECUTABLE}"
  "${CMAKE_CURRENT_LIST_DIR}/qspi_timing_test.py" --cc "${CMAKE_C_COMPILER}")

find_path(CJSON_SOURCE_DIR cJSON.c PATHS "$ENV{IDF_PATH}/components/json/cJSON" "$ENV{HOME}/esp-idf/components/json/cJSON" REQUIRED)
add_executable(sd_files_test sd_files_test.c "${CJSON_SOURCE_DIR}/cJSON.c" "${FW_ROOT}/main/sd_publish.c")
target_include_directories(sd_files_test PRIVATE "${CJSON_SOURCE_DIR}")
target_compile_options(sd_files_test PRIVATE -ffunction-sections -fdata-sections)
target_link_options(sd_files_test PRIVATE -Wl,--gc-sections)
target_link_libraries(sd_files_test PRIVATE lvgl_host m)
add_test(NAME sd_files COMMAND sd_files_test)
add_executable(sd_mount_test sd_mount_test.c)
target_link_libraries(sd_mount_test PRIVATE lvgl_host m)
add_test(NAME sd_mount COMMAND sd_mount_test)

add_executable(virtual_geometry_test virtual_geometry_test.c "${FW_ROOT}/main/cart_mapper.c")
target_compile_options(virtual_geometry_test PRIVATE -ffunction-sections -fdata-sections)
target_link_options(virtual_geometry_test PRIVATE -Wl,--gc-sections)
target_link_libraries(virtual_geometry_test PRIVATE lvgl_host m)
add_test(NAME virtual_small_ram COMMAND virtual_geometry_test ram)
add_test(NAME virtual_rom_extent COMMAND virtual_geometry_test rom)
add_test(NAME virtual_folder_paths COMMAND virtual_geometry_test paths)

add_executable(virtual_transition_test virtual_transition_test.c "${FW_ROOT}/main/cart_rtc.c")
target_compile_options(virtual_transition_test PRIVATE -ffunction-sections -fdata-sections)
target_link_options(virtual_transition_test PRIVATE -Wl,--gc-sections)
target_link_libraries(virtual_transition_test PRIVATE lvgl_host m)
if(DEFINED VIRTUAL_CART_TEST_SOURCE)
  target_compile_definitions(virtual_transition_test PRIVATE CM_VIRTUAL_CART_SOURCE="${VIRTUAL_CART_TEST_SOURCE}")
endif()
add_test(NAME virtual_final_save COMMAND virtual_transition_test)
