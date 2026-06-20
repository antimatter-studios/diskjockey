#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Adds a read-only FSKit extension target to DiskJockey.xcodeproj.
#
# Generalizes scripts/add-ext4-target.rb into a reusable, parameterized
# generator. Where add-ext4-target.rb hard-coded the EXT4 names + linked
# the am-img-* container readers (-lqcow2/-lvhd/-lvhdx/-lvmdk), this
# script is driven by env vars and links ONLY the single filesystem
# static lib. It is intended for the read-only filesystem extensions
# (EROFS, SquashFS) whose crates don't pull in the disk-image container
# readers — they mount raw partitions / fs_core slices, not containers.
#
# What it does (in one shot, idempotent if re-run for the same target):
#   1. Adds file refs for <TARGET>/<each swift source>, Info.plist,
#      <TARGET>.entitlements, and the bridging header.
#   2. Adds a file ref for lib/<LIB>/lib<LIB>.a.
#   3. Creates a PBXNativeTarget "<TARGET>" of product-type
#      extensionkit-extension, mirroring the existing DiskJockeyEXT4
#      target's build settings (deployment 26.0, hardened runtime,
#      app-sandbox off, etc).
#   4. Sets build settings:
#        - PRODUCT_BUNDLE_IDENTIFIER = <BUNDLE_ID>
#        - CODE_SIGN_ENTITLEMENTS = <TARGET>/<TARGET>.entitlements
#        - INFOPLIST_FILE = <TARGET>/Info.plist
#        - SWIFT_OBJC_BRIDGING_HEADER = <TARGET>/<TARGET>-Bridging-Header.h
#        - HEADER_SEARCH_PATHS  += $(SRCROOT)/lib/<LIB>/include
#        - LIBRARY_SEARCH_PATHS += $(SRCROOT)/lib/<LIB>
#        - OTHER_LDFLAGS        += -l<LIB>      (NO container libs)
#   5. Adds Sources / Frameworks / Resources phases.
#   6. Links FSKit.framework + lib<LIB>.a + DiskJockeyLibrary.framework,
#      and adds a target dependency on DiskJockeyLibrary (the Swift code
#      does `import DiskJockeyLibrary`).
#   7. Adds the .appex to the main DiskJockey app's existing
#      "Embed ExtensionKit Extensions" copy-files phase + a target
#      dependency, so the extension ships embedded in the host app.
#
# Usage:
#   FS_TARGET=DiskJockeyEROFS \
#   FS_BUNDLE_ID=com.antimatterstudios.diskjockey.erofs \
#   FS_LIB=fs_erofs \
#   FS_SOURCES="ErofsFileSystem.swift ErofsVolume.swift" \
#       ruby -rxcodeproj scripts/add-fs-target.rb
#
# All four env vars are required. FS_SOURCES is a space-separated list.

require 'xcodeproj'

PROJECT_PATH = File.expand_path(File.join(__dir__, '..', 'DiskJockey.xcodeproj'))

def env!(name)
  v = ENV[name]
  abort "[add-fs] missing required env var #{name}" if v.nil? || v.strip.empty?
  v.strip
end

TARGET_NAME = env!('FS_TARGET')
BUNDLE_ID   = env!('FS_BUNDLE_ID')
LIB_NAME    = env!('FS_LIB')                       # e.g. "fs_erofs"
SWIFT_SRCS  = env!('FS_SOURCES').split(/\s+/)      # e.g. ["ErofsFileSystem.swift", ...]

puts "[add-fs] target=#{TARGET_NAME} bundle=#{BUNDLE_ID} lib=#{LIB_NAME} sources=#{SWIFT_SRCS.inspect}"

project = Xcodeproj::Project.open(PROJECT_PATH)

# -----------------------------------------------------------------------------
# Remove any pre-existing target with our name so this script is idempotent.
# -----------------------------------------------------------------------------
existing = project.targets.detect { |t| t.name == TARGET_NAME }
if existing
  puts "[add-fs] removing existing #{TARGET_NAME} target"
  main_app = project.targets.detect { |t| t.name == 'DiskJockey' }
  if main_app
    main_app.dependencies.reject! do |dep|
      dep.target && dep.target.name == TARGET_NAME
    end
    main_app.build_phases.each do |phase|
      next unless phase.respond_to?(:files) && phase.respond_to?(:display_name)
      phase.files.reject! do |bf|
        ref = bf.file_ref
        ref && ref.respond_to?(:path) && ref.path == "#{TARGET_NAME}.appex"
      end
    end
  end
  existing.remove_from_project
end

# -----------------------------------------------------------------------------
# 1. Find or create the main group for our target dir + vendor dir.
# -----------------------------------------------------------------------------
root_group = project.main_group

fs_group = root_group.find_subpath(TARGET_NAME, true)
fs_group.set_source_tree('SOURCE_ROOT')
fs_group.set_path(TARGET_NAME)

lib_group = root_group.find_subpath('lib', true)
lib_group.set_source_tree('SOURCE_ROOT')
lib_group.set_path('lib')
lib_sub = lib_group.find_subpath(LIB_NAME, true)
lib_sub.set_path(LIB_NAME)

# -----------------------------------------------------------------------------
# 2. Add (or re-use) file references.
# -----------------------------------------------------------------------------
def find_or_create_file_ref(group, path)
  group.files.detect { |f| f.path == path } || group.new_reference(path)
end

swift_files = SWIFT_SRCS.map { |f| find_or_create_file_ref(fs_group, f) }

info_plist_ref   = find_or_create_file_ref(fs_group, 'Info.plist')
entitlements_ref = find_or_create_file_ref(fs_group, "#{TARGET_NAME}.entitlements")
bridging_ref     = find_or_create_file_ref(fs_group, "#{TARGET_NAME}-Bridging-Header.h")
_ = [info_plist_ref, entitlements_ref, bridging_ref] # referenced via build settings, not phases

libfs_ref = find_or_create_file_ref(lib_sub, "lib#{LIB_NAME}.a")
libfs_ref.last_known_file_type = 'archive.ar'

# -----------------------------------------------------------------------------
# 3. Create the native target.
# -----------------------------------------------------------------------------
target = project.new(Xcodeproj::Project::Object::PBXNativeTarget)
project.targets << target
target.name         = TARGET_NAME
target.product_name = TARGET_NAME
target.product_type = 'com.apple.product-type.extensionkit-extension'

# Build the config list manually (the helper rejects extensionkit-extension).
list = project.new(Xcodeproj::Project::Object::XCConfigurationList)
%w[Release Debug].each do |cfg_name|
  cfg = project.new(Xcodeproj::Project::Object::XCBuildConfiguration)
  cfg.name = cfg_name
  cfg.build_settings = {}
  list.build_configurations << cfg
end
list.default_configuration_name       = 'Release'
list.default_configuration_is_visible = '0'
target.build_configuration_list = list

# Product reference (the .appex) — registered in the Products group.
products_group = project.products_group
appex_ref = products_group.new_reference("#{TARGET_NAME}.appex", :built_products)
appex_ref.include_in_index = '0'
appex_ref.explicit_file_type = 'wrapper.extensionkit-extension'
appex_ref.set_source_tree('BUILT_PRODUCTS_DIR')
target.product_reference = appex_ref

# -----------------------------------------------------------------------------
# 4. Build settings on both configs. Mirrors the live DiskJockeyEXT4 target,
#    minus the container-format header/lib/ldflag entries (this is a
#    read-only FS that links exactly one static lib).
# -----------------------------------------------------------------------------
common_settings = {
  'CLANG_CXX_LIBRARY'           => 'libc++',
  'CODE_SIGN_ENTITLEMENTS'      => "#{TARGET_NAME}/#{TARGET_NAME}.entitlements",
  'CODE_SIGN_IDENTITY'          => 'Apple Development',
  'CODE_SIGN_STYLE'             => 'Automatic',
  'CURRENT_PROJECT_VERSION'     => '2',
  'DEAD_CODE_STRIPPING'         => 'NO',
  'DEVELOPMENT_TEAM'            => '43UMKXZ8P4',
  'ENABLE_APP_SANDBOX'          => 'NO',
  'ENABLE_HARDENED_RUNTIME'     => 'YES',
  'ENABLE_USER_SCRIPT_SANDBOXING' => 'YES',
  'GENERATE_INFOPLIST_FILE'     => 'NO',
  'HEADER_SEARCH_PATHS'         => ['$(inherited)', "$(SRCROOT)/lib/#{LIB_NAME}/include"],
  'INFOPLIST_FILE'              => "#{TARGET_NAME}/Info.plist",
  'INFOPLIST_KEY_CFBundleDisplayName' => TARGET_NAME,
  'INFOPLIST_KEY_NSHumanReadableCopyright' => '',
  'LD_RUNPATH_SEARCH_PATHS'     => [
    '$(inherited)',
    '@executable_path/../Frameworks',
    '@executable_path/../../../../Frameworks',
  ],
  'LIBRARY_SEARCH_PATHS'        => ['$(inherited)', "$(SRCROOT)/lib/#{LIB_NAME}"],
  'MACOSX_DEPLOYMENT_TARGET'    => '26.0',
  'MARKETING_VERSION'           => '1.0.1',
  'OTHER_LDFLAGS'               => ['$(inherited)', "-l#{LIB_NAME}"],
  'PRODUCT_BUNDLE_IDENTIFIER'   => BUNDLE_ID,
  'PRODUCT_NAME'                => '$(TARGET_NAME)',
  'REGISTER_APP_GROUPS'         => 'NO',
  'SDKROOT'                     => 'macosx',
  'SKIP_INSTALL'                => 'YES',
  'SWIFT_EMIT_LOC_STRINGS'      => 'YES',
  'SWIFT_OBJC_BRIDGING_HEADER'  => "#{TARGET_NAME}/#{TARGET_NAME}-Bridging-Header.h",
  'SWIFT_VERSION'               => '5.0',
}

target.build_configurations.each do |cfg|
  cfg.build_settings.merge!(common_settings)
end

# -----------------------------------------------------------------------------
# 5. Build phases.
# -----------------------------------------------------------------------------
sources_phase    = project.new(Xcodeproj::Project::Object::PBXSourcesBuildPhase)
frameworks_phase = project.new(Xcodeproj::Project::Object::PBXFrameworksBuildPhase)
resources_phase  = project.new(Xcodeproj::Project::Object::PBXResourcesBuildPhase)
target.build_phases << sources_phase
target.build_phases << frameworks_phase
target.build_phases << resources_phase

swift_files.each { |ref| sources_phase.add_file_reference(ref) }

# FSKit.framework — reuse the existing SDK framework ref if one exists.
fskit_ref = project.frameworks_group.files.detect { |f| f.path&.end_with?('FSKit.framework') }
unless fskit_ref
  fskit_ref = project.frameworks_group.new_reference('System/Library/Frameworks/FSKit.framework')
  fskit_ref.name = 'FSKit.framework'
  fskit_ref.source_tree = 'SDKROOT'
end
frameworks_phase.add_file_reference(fskit_ref)
frameworks_phase.add_file_reference(libfs_ref)

# DiskJockeyLibrary.framework — the extension's Swift code does
# `import DiskJockeyLibrary`. Link the already-built framework product
# and add a target dependency so it's built first. Reuse the existing
# product file ref the other targets share.
djlib_target = project.targets.detect { |t| t.name == 'DiskJockeyLibrary' }
djlib_product = djlib_target&.product_reference
if djlib_product
  frameworks_phase.add_file_reference(djlib_product)
  target.add_dependency(djlib_target)
else
  warn "[add-fs] WARNING: DiskJockeyLibrary target/product not found — skipping framework link"
end

# -----------------------------------------------------------------------------
# 6. Wire embed-into-main-app via the EXISTING "Embed ExtensionKit
#    Extensions" copy-files phase (dstSubfolderSpec 16 / EXTENSIONS_FOLDER_PATH),
#    which is what the live DiskJockeyEXT4 + DiskJockeyNTFS .appex use.
# -----------------------------------------------------------------------------
main_app = project.targets.detect { |t| t.name == 'DiskJockey' }
if main_app
  main_app.add_dependency(target)

  embed_phase = main_app.copy_files_build_phases.detect do |p|
    p.name == 'Embed ExtensionKit Extensions' ||
      (p.dst_subfolder_spec.to_s == '16' && p.name.to_s =~ /ExtensionKit/i)
  end
  unless embed_phase
    embed_phase = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
    embed_phase.name = 'Embed ExtensionKit Extensions'
    embed_phase.symbol_dst_subfolder_spec = :plug_ins rescue nil
    embed_phase.dst_subfolder_spec = '16'
    embed_phase.dst_path = '$(EXTENSIONS_FOLDER_PATH)'
    main_app.build_phases << embed_phase
  end

  already = embed_phase.files.detect { |f| f.file_ref == appex_ref }
  unless already
    bf = embed_phase.add_file_reference(appex_ref)
    bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
  end
else
  warn "[add-fs] WARNING: main DiskJockey app target not found — extension will not be embedded"
end

# -----------------------------------------------------------------------------
# 7. Save.
# -----------------------------------------------------------------------------
project.save
puts "[add-fs] wrote #{PROJECT_PATH}"
puts "[add-fs] target list now:"
project.targets.each { |t| puts "  - #{t.name} (#{t.product_type})" }
