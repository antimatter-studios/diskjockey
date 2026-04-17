#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Adds the DiskJockeyEXT4 FSKit extension target to DiskJockey.xcodeproj.
#
# What this does (in one shot, idempotent if re-run):
#   1. Adds file refs for DiskJockeyEXT4/{EXT4FileSystem,EXT4Volume,EXT4Item,
#      EXT4Backend,FileSystemBackend}.swift, Info.plist, entitlements,
#      and the bridging header.
#   2. Adds file refs for vendor/ext4rs/libext4rs.a + ext4rs.h.
#   3. Creates a PBXNativeTarget "DiskJockeyEXT4" of type
#      extensionkit-extension, mirroring DiskJockeyFileProvider's config.
#   4. Sets build settings:
#        - PRODUCT_BUNDLE_IDENTIFIER = com.antimatterstudios.diskjockey.ext4
#        - CODE_SIGN_ENTITLEMENTS = DiskJockeyEXT4/DiskJockeyEXT4.entitlements
#        - INFOPLIST_FILE = DiskJockeyEXT4/Info.plist
#        - SWIFT_OBJC_BRIDGING_HEADER = DiskJockeyEXT4/DiskJockeyEXT4-Bridging-Header.h
#        - HEADER_SEARCH_PATHS += $(SRCROOT)/vendor/ext4rs/include
#        - LIBRARY_SEARCH_PATHS += $(SRCROOT)/vendor/ext4rs
#        - OTHER_LDFLAGS += -lext4rs
#   5. Adds Sources, Frameworks, Resources phases.
#   6. Links FSKit.framework + libext4rs.a.
#   7. Adds embed-app-extensions phase on the main DiskJockey target so the
#      .appex ships with the host app.
#
# Usage:
#   GEM_PATH=~/.gem/ruby/2.6.0 ruby -I~/.gem/ruby/2.6.0/gems/xcodeproj-1.27.0/lib \
#       scripts/add-ext4-target.rb
#
# Or (with any gem install path):
#   ruby -rxcodeproj scripts/add-ext4-target.rb

require 'xcodeproj'

PROJECT_PATH = File.expand_path(File.join(__dir__, '..', 'DiskJockey.xcodeproj'))
TARGET_NAME  = 'DiskJockeyEXT4'
BUNDLE_ID    = 'com.antimatterstudios.diskjockey.ext4'

project = Xcodeproj::Project.open(PROJECT_PATH)

# -----------------------------------------------------------------------------
# Remove any pre-existing target with our name so this script is idempotent.
# -----------------------------------------------------------------------------
existing = project.targets.detect { |t| t.name == TARGET_NAME }
if existing
  puts "[add-ext4] removing existing #{TARGET_NAME} target"
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

ext4_group = root_group.find_subpath(TARGET_NAME, true)
ext4_group.set_source_tree('SOURCE_ROOT')
ext4_group.set_path(TARGET_NAME)

vendor_group  = root_group.find_subpath('vendor', true)
vendor_group.set_source_tree('SOURCE_ROOT')
vendor_group.set_path('vendor')
ext4rs_group  = vendor_group.find_subpath('ext4rs', true)
ext4rs_group.set_path('ext4rs')

# -----------------------------------------------------------------------------
# 2. Add (or re-use) file references.
# -----------------------------------------------------------------------------
def find_or_create_file_ref(group, path)
  group.files.detect { |f| f.path == path } ||
    group.new_reference(path)
end

swift_files = %w[
  EXT4FileSystem.swift
  EXT4Volume.swift
  EXT4Item.swift
  EXT4Backend.swift
  FileSystemBackend.swift
].map { |f| find_or_create_file_ref(ext4_group, f) }

info_plist_ref    = find_or_create_file_ref(ext4_group, 'Info.plist')
entitlements_ref  = find_or_create_file_ref(ext4_group, "#{TARGET_NAME}.entitlements")
bridging_ref      = find_or_create_file_ref(ext4_group, "#{TARGET_NAME}-Bridging-Header.h")

libext4rs_ref = find_or_create_file_ref(ext4rs_group, 'libext4rs.a')
libext4rs_ref.last_known_file_type = 'archive.ar'

# -----------------------------------------------------------------------------
# 3. Create the native target.
# -----------------------------------------------------------------------------
target = project.new(Xcodeproj::Project::Object::PBXNativeTarget)
project.targets << target
target.name              = TARGET_NAME
target.product_name      = TARGET_NAME
target.product_type      = 'com.apple.product-type.extensionkit-extension'
target.build_configuration_list =
  Xcodeproj::Project::ProjectHelper.configuration_list(
    project, :osx, '13.0', :swift, :extensionkit_extension
  ) rescue nil

# Fallback: build the config list manually if the helper rejects the type.
unless target.build_configuration_list
  list = project.new(Xcodeproj::Project::Object::XCConfigurationList)
  %w[Debug Release].each do |cfg_name|
    cfg = project.new(Xcodeproj::Project::Object::XCBuildConfiguration)
    cfg.name = cfg_name
    cfg.build_settings = {}
    list.build_configurations << cfg
  end
  list.default_configuration_name      = 'Release'
  list.default_configuration_is_visible = '0'
  target.build_configuration_list = list
end

# Product reference (the .appex) — registered in the Products group.
products_group = project.products_group
appex_ref = products_group.new_reference("#{TARGET_NAME}.appex", :built_products)
appex_ref.include_in_index = '0'
appex_ref.explicit_file_type = 'wrapper.extensionkit-extension'
appex_ref.set_source_tree('BUILT_PRODUCTS_DIR')
target.product_reference = appex_ref

# -----------------------------------------------------------------------------
# 4. Build settings on both configs.
# -----------------------------------------------------------------------------
common_settings = {
  'CODE_SIGN_ENTITLEMENTS'      => "#{TARGET_NAME}/#{TARGET_NAME}.entitlements",
  'CODE_SIGN_STYLE'             => 'Automatic',
  'CURRENT_PROJECT_VERSION'     => '1',
  'DEAD_CODE_STRIPPING'         => 'YES',
  'DEVELOPMENT_TEAM'            => '43UMKXZ8P4',
  'ENABLE_HARDENED_RUNTIME'     => 'YES',
  'GENERATE_INFOPLIST_FILE'     => 'NO',
  'INFOPLIST_FILE'              => "#{TARGET_NAME}/Info.plist",
  'INFOPLIST_KEY_CFBundleDisplayName' => TARGET_NAME,
  'INFOPLIST_KEY_NSHumanReadableCopyright' => '',
  'LD_RUNPATH_SEARCH_PATHS'     => [
    '$(inherited)',
    '@executable_path/../Frameworks',
    '@executable_path/../../../../Frameworks',
  ],
  'MARKETING_VERSION'           => '1.0',
  'PRODUCT_BUNDLE_IDENTIFIER'   => BUNDLE_ID,
  'PRODUCT_NAME'                => '$(TARGET_NAME)',
  'REGISTER_APP_GROUPS'         => 'YES',
  'SKIP_INSTALL'                => 'YES',
  'SWIFT_EMIT_LOC_STRINGS'      => 'YES',
  'SWIFT_VERSION'               => '5.0',
  'SWIFT_OBJC_BRIDGING_HEADER'  => "#{TARGET_NAME}/#{TARGET_NAME}-Bridging-Header.h",
  'HEADER_SEARCH_PATHS'         => ['$(inherited)', '$(SRCROOT)/vendor/ext4rs/include'],
  'LIBRARY_SEARCH_PATHS'        => ['$(inherited)', '$(SRCROOT)/vendor/ext4rs'],
  'OTHER_LDFLAGS'               => ['$(inherited)', '-lext4rs'],
  'MACOSX_DEPLOYMENT_TARGET'    => '15.0',
  'SDKROOT'                     => 'macosx',
  'ENABLE_USER_SCRIPT_SANDBOXING' => 'YES',
}

target.build_configurations.each do |cfg|
  cfg.build_settings.merge!(common_settings)
end

# -----------------------------------------------------------------------------
# 5. Build phases.
# -----------------------------------------------------------------------------
sources_phase    = target.new_shell_script_build_phase('Sources')  # placeholder
# Replace with real Sources phase
target.build_phases.delete(sources_phase)
sources_phase    = project.new(Xcodeproj::Project::Object::PBXSourcesBuildPhase)
frameworks_phase = project.new(Xcodeproj::Project::Object::PBXFrameworksBuildPhase)
resources_phase  = project.new(Xcodeproj::Project::Object::PBXResourcesBuildPhase)
target.build_phases << sources_phase
target.build_phases << frameworks_phase
target.build_phases << resources_phase

swift_files.each { |ref| sources_phase.add_file_reference(ref) }

# FSKit.framework — look up the SDK framework, adding a file ref if needed.
fskit_ref = project.frameworks_group.files.detect { |f| f.path&.end_with?('FSKit.framework') }
unless fskit_ref
  fskit_ref = project.frameworks_group.new_reference(
    'System/Library/Frameworks/FSKit.framework'
  )
  fskit_ref.name = 'FSKit.framework'
  fskit_ref.source_tree = 'SDKROOT'
end
frameworks_phase.add_file_reference(fskit_ref)
frameworks_phase.add_file_reference(libext4rs_ref)

# -----------------------------------------------------------------------------
# 6. Wire embed-into-main-app.
# -----------------------------------------------------------------------------
main_app = project.targets.detect { |t| t.name == 'DiskJockey' }
if main_app
  # Dependency
  main_app.add_dependency(target)

  # Embed Foundation Extensions phase — create if absent.
  embed_phase = main_app.copy_files_build_phases.detect do |p|
    p.dst_subfolder_spec == '13' && p.name =~ /Extensions|Foundation Extensions/i
  end
  unless embed_phase
    embed_phase = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
    embed_phase.name = 'Embed Foundation Extensions'
    embed_phase.dst_subfolder_spec = '13' # PlugIns
    embed_phase.dst_path = ''
    main_app.build_phases << embed_phase
  end

  # Attach our .appex
  already = embed_phase.files.detect { |f| f.file_ref == appex_ref }
  unless already
    bf = embed_phase.add_file_reference(appex_ref)
    bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
  end
end

# -----------------------------------------------------------------------------
# 7. Save.
# -----------------------------------------------------------------------------
project.save
puts "[add-ext4] wrote #{PROJECT_PATH}"
puts "[add-ext4] target list now:"
project.targets.each { |t| puts "  - #{t.name} (#{t.product_type})" }
