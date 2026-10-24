#!/usr/bin/env ruby

require "xcodeproj"
require "yaml"

project_path = File.expand_path("../ios/Runner.xcodeproj", __dir__)
project_dir = File.dirname(project_path)
mobile_framework = File.join(project_dir, "mobileapi.xcframework")
abort("missing #{mobile_framework}; run scripts/build-ios.py") unless Dir.exist?(mobile_framework)

project = Xcodeproj::Project.open(project_path)
pubspec = YAML.safe_load(File.read(File.expand_path("../pubspec.yaml", __dir__)))
version, build_number = pubspec.fetch("version").split("+", 2)
runner = project.targets.find { |target| target.name == "Runner" }
abort("Runner target not found") unless runner

runner.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "app.aster.desktop"
  settings["IPHONEOS_DEPLOYMENT_TARGET"] = "16.0"
  settings["CODE_SIGN_ENTITLEMENTS"] = "Runner/Runner.entitlements"
  settings["OTHER_LDFLAGS"] = [settings["OTHER_LDFLAGS"], "-ObjC"].compact.join(" ")
end

runner_group = project.main_group.find_subpath("Runner", false)
shared_group = project.main_group.find_subpath("Shared", true)
shared_group.path = "Shared"

def ensure_file(group, name, path = nil)
  group.files.find { |file| file.path == (path || name) } ||
    group.new_file(path || name)
end

def ensure_source(target, reference)
  target.source_build_phase.files_references.each do |existing|
    return if existing == reference
  end
  target.source_build_phase.add_file_reference(reference, true)
end

ensure_source(runner, ensure_file(runner_group, "AsterIOSHost.swift"))
ensure_source(runner, ensure_file(runner_group, "AsterAppIntents.swift"))
runtime = ensure_file(shared_group, "AsterIOSRuntime.swift")
ensure_source(runner, runtime)

extension = project.targets.find { |target| target.name == "AsterTunnel" }
unless extension
  extension = project.new_target(:app_extension, "AsterTunnel", :ios, "16.0")
end

extension_group = project.main_group.find_subpath("AsterTunnel", true)
extension_group.path = "AsterTunnel"
provider = ensure_file(extension_group, "AsterTunnelProvider.swift")
ensure_source(extension, provider)
ensure_source(extension, runtime)

extension.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "app.aster.desktop.tunnel"
  settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
  settings["INFOPLIST_FILE"] = "AsterTunnel/Info.plist"
  settings["CODE_SIGN_ENTITLEMENTS"] = "AsterTunnel/AsterTunnel.entitlements"
  settings["MARKETING_VERSION"] = version
  settings["CURRENT_PROJECT_VERSION"] = build_number || "1"
  settings["IPHONEOS_DEPLOYMENT_TARGET"] = "16.0"
  settings["APPLICATION_EXTENSION_API_ONLY"] = "YES"
  settings["SWIFT_VERSION"] = "5.0"
  settings["LD_RUNPATH_SEARCH_PATHS"] = [
    "$(inherited)",
    "@executable_path/Frameworks",
    "@executable_path/../../Frameworks",
  ]
end

framework_ref = project.frameworks_group.files.find { |file| file.path == "mobileapi.xcframework" }
framework_ref ||= project.frameworks_group.new_file(mobile_framework)
framework_ref.source_tree = "<group>"
framework_ref.path = mobile_framework

def link_framework(target, reference)
  target.frameworks_build_phase.files_references.compact.each do |existing|
    return if existing == reference
  end
  target.frameworks_build_phase.add_file_reference(reference, true)
end

def embed_framework(target, reference)
  phase = target.copy_files_build_phases.find { |item| item.name == "Embed Frameworks" }
  unless phase
    phase = target.new_copy_files_build_phase("Embed Frameworks")
    phase.dst_subfolder_spec = :frameworks
  end
  phase.files_references.compact.each do |existing|
    return if existing == reference
  end
  build_file = phase.add_file_reference(reference, true)
  build_file.settings = {
    "ATTRIBUTES" => ["CodeSignOnCopy", "RemoveHeadersOnCopy"],
  }
end

[runner, extension].each do |target|
  target.add_system_framework("NetworkExtension") unless target.frameworks_build_phase.files_references.compact.any? {
    |file| file.path == "NetworkExtension.framework"
  }
  link_framework(target, framework_ref)
  embed_framework(target, framework_ref)
end

unless runner.dependencies.any? { |dependency| dependency.target == extension }
  runner.add_dependency(extension)
end

embed_extensions = runner.copy_files_build_phases.find { |phase| phase.name == "Embed App Extensions" }
unless embed_extensions
  embed_extensions = runner.new_copy_files_build_phase("Embed App Extensions")
  embed_extensions.dst_subfolder_spec = :plug_ins
end
unless embed_extensions.files_references.include?(extension.product_reference)
  build_file = embed_extensions.add_file_reference(extension.product_reference, true)
  build_file.settings = {
    "ATTRIBUTES" => ["CodeSignOnCopy", "RemoveHeadersOnCopy"],
  }
end

project.save
puts "Configured Runner and AsterTunnel targets"
