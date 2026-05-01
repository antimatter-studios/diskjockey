#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Adds the DiskJockeyMountHelper privileged-helper target to
# DiskJockey.xcodeproj. Spike scope — minimal command-line-tool
# binary that launchd spawns via SMAppService.daemon, exposes one
# XPC method (`ping`).
#
# What this does (idempotent):
#   1. Creates a PBXNativeTarget "DiskJockeyMountHelper" of type
#      `com.apple.product-type.tool` (Command Line Tool).
#   2. Adds main.swift + MountHelperProtocol.swift to the helper's
#      Sources phase.
#   3. Adds MountHelperProtocol.swift to the MAIN DiskJockey app's
#      Sources phase too — same .swift source compiled into both
#      targets so the @objc protocol identity matches at runtime.
#   4. Adds a Copy Files build phase on the main app to embed the
#      helper binary at `Contents/MacOS/com.antimatterstudios.diskjockey.mounthelper`.
#   5. Adds a Copy Files build phase on the main app to embed the
#      launchd plist at `Contents/Library/LaunchDaemons/`.
#   6. Sets the main app as a build dependency of helper installation.
#
# Usage:
#   ruby -rxcodeproj scripts/add-mounthelper-target.rb

require 'xcodeproj'

PROJECT_PATH = File.expand_path(File.join(__dir__, '..', 'DiskJockey.xcodeproj'))
TARGET_NAME  = 'DiskJockeyMountHelper'
EXEC_NAME    = 'com.antimatterstudios.diskjockey.mounthelper'
PLIST_NAME   = "#{EXEC_NAME}.plist"

project = Xcodeproj::Project.open(PROJECT_PATH)

# -----------------------------------------------------------------------------
# Idempotency: tear down any pre-existing version of this target.
# -----------------------------------------------------------------------------
existing = project.targets.detect { |t| t.name == TARGET_NAME }
if existing
  puts "[add-mounthelper] removing existing #{TARGET_NAME} target"
  main_app = project.targets.detect { |t| t.name == 'DiskJockey' }
  if main_app
    main_app.dependencies.reject! do |dep|
      dep.target && dep.target.name == TARGET_NAME
    end
    main_app.build_phases.each do |phase|
      next unless phase.respond_to?(:files) && phase.respond_to?(:display_name)
      phase.files.reject! do |bf|
        ref = bf.file_ref
        ref && ref.respond_to?(:path) &&
          (ref.path == EXEC_NAME || ref.path == PLIST_NAME)
      end
    end
    # Drop our previously-added Copy Files phases (matched by name).
    main_app.build_phases.reject! do |p|
      p.is_a?(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase) &&
        ['Embed MountHelper Binary', 'Embed MountHelper Plist'].include?(p.name)
    end
  end
  existing.remove_from_project
end

# -----------------------------------------------------------------------------
# 1. Group + file refs.
# -----------------------------------------------------------------------------
root_group = project.main_group
helper_group = root_group.find_subpath(TARGET_NAME, true)
helper_group.set_source_tree('SOURCE_ROOT')
helper_group.set_path(TARGET_NAME)

def find_or_create_file_ref(group, path)
  group.files.detect { |f| f.path == path } || group.new_reference(path)
end

main_swift_ref     = find_or_create_file_ref(helper_group, 'main.swift')
protocol_swift_ref = find_or_create_file_ref(helper_group, 'MountHelperProtocol.swift')
launchd_plist_ref  = find_or_create_file_ref(helper_group, PLIST_NAME)
entitlements_ref   = find_or_create_file_ref(helper_group, "#{TARGET_NAME}.entitlements")

# -----------------------------------------------------------------------------
# 2. Native target — Command Line Tool product type.
# -----------------------------------------------------------------------------
target = project.new(Xcodeproj::Project::Object::PBXNativeTarget)
project.targets << target
target.name         = TARGET_NAME
target.product_name = EXEC_NAME
target.product_type = 'com.apple.product-type.tool'

list = project.new(Xcodeproj::Project::Object::XCConfigurationList)
%w[Debug Release].each do |cfg_name|
  cfg = project.new(Xcodeproj::Project::Object::XCBuildConfiguration)
  cfg.name = cfg_name
  cfg.build_settings = {}
  list.build_configurations << cfg
end
list.default_configuration_name = 'Release'
list.default_configuration_is_visible = '0'
target.build_configuration_list = list

# Product reference — the unwrapped tool binary.
products_group = project.products_group
tool_ref = products_group.new_reference(EXEC_NAME, :built_products)
tool_ref.include_in_index = '0'
tool_ref.explicit_file_type = 'compiled.mach-o.executable'
tool_ref.set_source_tree('BUILT_PRODUCTS_DIR')
target.product_reference = tool_ref

common_settings = {
  'CODE_SIGN_ENTITLEMENTS'      => "#{TARGET_NAME}/#{TARGET_NAME}.entitlements",
  'CODE_SIGN_STYLE'             => 'Automatic',
  'CURRENT_PROJECT_VERSION'     => '1',
  'DEAD_CODE_STRIPPING'         => 'YES',
  'DEVELOPMENT_TEAM'            => '43UMKXZ8P4',
  'ENABLE_HARDENED_RUNTIME'     => 'YES',
  'MACOSX_DEPLOYMENT_TARGET'    => '15.0',
  'MARKETING_VERSION'           => '1.0',
  'PRODUCT_BUNDLE_IDENTIFIER'   => EXEC_NAME,
  'PRODUCT_NAME'                => EXEC_NAME,
  'SDKROOT'                     => 'macosx',
  'SKIP_INSTALL'                => 'YES',
  'SWIFT_VERSION'               => '5.0',
  'ENABLE_USER_SCRIPT_SANDBOXING' => 'YES',
  # Command-line tools default to no Info.plist; we don't ship one.
  #
  # codesign treats trailing `.<word>` as a file extension and strips
  # it when computing the default identifier — so a binary named
  # `com.antimatterstudios.diskjockey.mounthelper` would get signed
  # with identifier `com.antimatterstudios.diskjockey` (matching the
  # parent app, breaking SMAppService validation). Force the full id
  # via an explicit --identifier flag.
  'OTHER_CODE_SIGN_FLAGS'       => "$(inherited) --identifier #{EXEC_NAME}",
}
target.build_configurations.each { |cfg| cfg.build_settings.merge!(common_settings) }

# -----------------------------------------------------------------------------
# 3. Sources phase on helper target.
# -----------------------------------------------------------------------------
sources_phase = project.new(Xcodeproj::Project::Object::PBXSourcesBuildPhase)
target.build_phases << sources_phase
sources_phase.add_file_reference(main_swift_ref)
sources_phase.add_file_reference(protocol_swift_ref)

# -----------------------------------------------------------------------------
# 4. Add MountHelperProtocol.swift to the main app's Sources phase too,
#    so app + helper share the @objc type identity. Defensive: skip if
#    already there from a prior run.
# -----------------------------------------------------------------------------
main_app = project.targets.detect { |t| t.name == 'DiskJockey' }
abort '[add-mounthelper] DiskJockey target not found — aborting' unless main_app

main_sources = main_app.build_phases.detect { |p| p.is_a?(Xcodeproj::Project::Object::PBXSourcesBuildPhase) }
abort '[add-mounthelper] main app has no Sources phase' unless main_sources
unless main_sources.files.any? { |bf| bf.file_ref == protocol_swift_ref }
  main_sources.add_file_reference(protocol_swift_ref)
end

# -----------------------------------------------------------------------------
# 5. Build dependency.
# -----------------------------------------------------------------------------
main_app.add_dependency(target)

# -----------------------------------------------------------------------------
# 6. Copy Files phase: embed the helper binary at Contents/MacOS.
#    dst_subfolder_spec = 6 (Executables — i.e. Contents/MacOS).
# -----------------------------------------------------------------------------
embed_bin = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
embed_bin.name = 'Embed MountHelper Binary'
embed_bin.dst_subfolder_spec = '6'
embed_bin.dst_path = ''
main_app.build_phases << embed_bin
embed_bin.add_file_reference(tool_ref)

# -----------------------------------------------------------------------------
# 7. Copy Files phase: embed the launchd plist at Contents/Library/LaunchDaemons.
#    dst_subfolder_spec = 1 (wrapper root) + custom dst_path.
# -----------------------------------------------------------------------------
embed_plist = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
embed_plist.name = 'Embed MountHelper Plist'
embed_plist.dst_subfolder_spec = '1'
# LaunchAgents (user context, unsandboxed) — NOT LaunchDaemons. Sandboxed
# apps cannot register `.daemon` (root-context) services but CAN register
# `.agent` (user-context). The agent itself runs without the App Sandbox
# so DADiskMount succeeds, while the parent app stays sandboxed for MAS.
embed_plist.dst_path = 'Contents/Library/LaunchAgents'
main_app.build_phases << embed_plist
embed_plist.add_file_reference(launchd_plist_ref)

# -----------------------------------------------------------------------------
# 8. Save.
# -----------------------------------------------------------------------------
project.save
puts "[add-mounthelper] wrote #{PROJECT_PATH}"
puts "[add-mounthelper] target list now:"
project.targets.each { |t| puts "  - #{t.name} (#{t.product_type})" }
