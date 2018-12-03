#! /usr/bin/env ruby
# encoding: UTF-8
#
# Author: shayanbo

require 'fileutils'
require 'xcodeproj'
require 'pathname'
require 'yaml'
require 'json'
require 'cfpropertylist'
require 'cocoapods-core'
require 'optparse'
require 'colored2/object'

module Apollon

	APOLLON = 'Apollon'
	VERSION = '0.0.1'

	module UI

		def self.title(msg)
			$stdout.puts msg.green.bold
		end

		def self.done
			$stdout.puts '['.green.bold + 'Apollon'.green + '] '.green.bold + 'Done!'.green.bold
		end

		def self.notice(msg)
			$stdout.puts '['.green.bold + 'Apollon'.green + '] '.green.bold + msg.green.bold
		end

		def self.warn(msg)
			$stdout.puts '['.yellow.bold + 'Apollon'.yellow + '] '.yellow.bold + msg.yellow.bold
		end

		def self.error(msg)
			$stderr.puts '['.red.bold + 'Apollon'.red + '] '.red.bold + msg.red.bold
		end

	end

	module Location

		def self.podfile
			File.expand_path('../Podfile', pod_project_dir)
		end

		def self.podfile_lock
			File.expand_path('../Podfile.lock', pod_project_dir)
		end

		def self.apollon_home
			File.join(Dir.home, ".apollon")
		end

		def self.pod_project_path
			ENV['PROJECT_FILE_PATH']
		end

		def self.pod_project_dir
			ENV['PROJECT_DIR']
		end

		def self.lib_path_in_apollon(target, pod_uuid)

			configuration = "#{ENV['CONFIGURATION']}-#{ENV['PLATFORM_NAME']}/#{ENV['ARCHS'].split.sort.join('_')}"
			lib_dir_in_a = File.join(apollon_home, target.name, pod_uuid, configuration)
			FileUtils.mkdir_p(lib_dir_in_a) unless Dir.exist?(lib_dir_in_a)
			File.join(lib_dir_in_a, "lib#{target.name}.a")
		end

		def self.lib_dir_in_apollon(target, pod_uuid)
			path = lib_path_in_apollon(target, pod_uuid)
			Pathname.new(path).dirname
		end

		def self.lib_path_in_xcode(pod_name)
			File.join(ENV['BUILT_PRODUCTS_DIR'], pod_name, "lib#{pod_name}.a")
		end

		def self.lib_dir_in_xcode(pod_name)
			path = lib_path_in_xcode(pod_name)
			Pathname.new(path).dirname
		end

		def self.apollon_file_path
			File.join(pod_project_dir, "#{APOLLON}file")
		end
	end

	module Cache

		CACHE_UPPER_LIMIT = 1024 * 1024 * 1024 # 1G upper limit

		def self.clean
			FileUtils.remove_dir(Location.apollon_home) if Dir.exists?(Location.apollon_home)
		end

		def self.clean_old

			apollon_home_size = 0
			libraries = Dir.glob(File.join(Location.apollon_home, '**/*'))

			# caculate apollon size
			libraries.each do |file_path|
				apollon_home_size += File.size(file_path)
			end
			if apollon_home_size < CACHE_UPPER_LIMIT
				UI.notice('Cache size is less than 1G!')
				return
			end

			# sort using modification time
			libraries.sort! do |lhs, rhs| File.new(lhs).mtime <=> File.new(rhs).mtime end

			# sum deletable files
			size_to_delete = apollon_home_size - CACHE_UPPER_LIMIT
			deletable_files = []
			libraries.each do |file_path|
				size_to_delete -= File.size(file_path)
				if (size_to_delete > 0)
					deletable_files << file_path
				end
			end

			# delete
			deletable_files.each do |file|
				UI.notice("Delete #{file},  Last Time of Usage is #{File.new(file).mtime}.")
				FileUtils.remove_entry(file)
			end
		end

	end

	module RuntimeMethod

		def self.parse_podfile_lock
			@pod_lock ||= YAML.load(File.open(Location.podfile_lock))
		end

		def self.is_dev_pod(pod_name)
			return false if parse_podfile_lock['EXTERNAL SOURCES'].nil?
			return false if parse_podfile_lock['EXTERNAL SOURCES'][pod_name].nil?
			!parse_podfile_lock['EXTERNAL SOURCES'][pod_name][:path].nil?
		end

		def self.commit_sha1_of_dev_pod(pod_name)

			target = pod_project.targets.select do |aTarget| aTarget.name == pod_name end.first
			relative_path = parse_podfile_lock['EXTERNAL SOURCES'][pod_name][:path]

			spec_dir = File.expand_path(relative_path, "#{Location.pod_project_dir}/..")
			report_error "#{spec_dir} is not git repo!" unless Dir.exists?(File.join(spec_dir, '.git'))
			%x{git rev-parse --short HEAD}.strip
		end

		def self.checksum_of_pod(pod_name)
			parse_podfile_lock['SPEC CHECKSUMS'][pod_name]
		end

		def self.parse_apollon_config

			if @apo_config.nil?
				plist = CFPropertyList::List.new(:file => Location.apollon_file_path)
				@apo_config = CFPropertyList.native_types(plist.value)
			end
			@apo_config
		end

		def self.parse_apollon_lock

			if @apo_lock.nil?
				plist = CFPropertyList::List.new(:file => Location.apollon_file_path)
				@apo_lock = CFPropertyList.native_types(plist.value)
			end
			@apo_lock
		end

		def self.recover_compile_source_content(target, project = pod_project)

			return if target.name == APOLLON
			source_mapping_dir = File.join(project.project_dir, 'Sources Mappings')
			source_mapping_file = File.join(source_mapping_dir, "#{target.name}.cs.json")
			return unless File.exists?(source_mapping_file)
			mapping = JSON.load(File.read(source_mapping_file))
			mapping.each do |item|
				uuid = item.is_a?(String) ? item : item.keys.first
				source_file_ref = project.objects_by_uuid[uuid]
				source_build_file = target.source_build_phase.add_file_reference(source_file_ref, true)
				if item.is_a?(Hash)
					source_build_file.settings = {'COMPILER_FLAGS' => item[uuid]}
				end
			end
		end

		def self.commit_id_of_pod_in_xcode(pod_name)
			commit = checksum_of_pod(pod_name)
			commit = commit_sha1_of_dev_pod(pod_name) if is_dev_pod(pod_name)
			commit
		end

		def self.synchronize_apollon_and_xcode

			dirty = false

			# apollonfile format check
			parse_apollon_config.each do |target_name, static_enable|
				if pod_project.targets.find do |target| target.name == target_name end.nil?
					report_error "#{target_name} Not Found!"
				end
				unless static_enable.is_a?(TrueClass) || static_enable.is_a?(FalseClass)
					report_error "Configuration of #{target_name} is wrong!"
				end
			end

			# dev pod dirty check
			pod_project.targets.select do |target|
				parse_apollon_config[target.name]
			end.each do |target|
				next unless is_dev_pod(target.name)
				relative_path = parse_podfile_lock['EXTERNAL SOURCES'][target.name][:path]
				spec_dir = File.expand_path(relative_path, "#{Location.pod_project_dir}/..")
				next if %x(git -C #{spec_dir} status -s | wc -l).strip == '0'
				report_error "#{spec_dir} is dirty!"
			end

			output = Array.new
			pod_project.targets.each do |target|

				if parse_apollon_config[target.name]

					commit_id = commit_id_of_pod_in_xcode(target.name)
					lib_path_in_a = Location.lib_path_in_apollon(target, commit_id)
					lib_path_in_x = Location.lib_path_in_xcode(target.name)

					if File.exists?(lib_path_in_a)
						FileUtils.rm_f(lib_path_in_x) if File.exists?(lib_path_in_x)
						FileUtils.touch(lib_path_in_a)
						FileUtils.symlink(lib_path_in_a, lib_path_in_x)
					end

					exists_lib_in_xcode = File.exists?(lib_path_in_x) && File.symlink?(lib_path_in_x)
					if exists_lib_in_xcode
						unless target.source_build_phase.files.empty?
							dirty = true
							target.source_build_phase.clear
							output << "#{target.name}: Turn on Staticization!"
						end
          else
						if target.source_build_phase.files.empty?
							dirty = true
							recover_compile_source_content(target)
							output << "#{target.name}: Turn off Staticization!"
						end
					end
        else
					if target.source_build_phase.files.empty?
						dirty = true
						recover_compile_source_content(target)
						output << "#{target.name}: Turn off Staticization!"
					end
				end
			end

			# lock files
			pod_project.targets.select do |target|

				next unless is_dev_pod(target.name)
				next unless File.exists?(Location.lib_path_in_xcode(target.name))

				relative_path = parse_podfile_lock['EXTERNAL SOURCES'][target.name][:path]
				spec_dir = File.expand_path(relative_path, "#{Location.pod_project_dir}/..")
				should_be_static = parse_apollon_config[target.name]

				spec_dir_expression = File.expand_path("**/*.{h,m,mm,c,cc}", spec_dir)
				Dir.glob(spec_dir_expression) do |file|
					unless File.directory?(file)
						FileUtils.chmod(should_be_static ? "u-w" : "u+w", file)
					end
				end
			end

			if dirty
				pod_project.save
				output.each do |line| $stderr.puts line end
				report_error "[Apollon] Re-Run!"
			end
		end

		def self.collect_libraries_from_xcode

			pod_project.targets.select do |target|
				parse_apollon_config[target.name]
			end.each do |target|
				exists_in_xcode = File.exists?(Location.lib_path_in_xcode(target.name))
				commit_id = commit_id_of_pod_in_xcode(target.name)
				exists_in_apollon = File.exists?(Location.lib_path_in_apollon(target, commit_id))
				if exists_in_xcode && !exists_in_apollon
					FileUtils.cp(Location.lib_path_in_xcode(target.name), Location.lib_dir_in_apollon(target, commit_id))
				end
			end
		end

		def self.pod_project
			@pod_project ||= Xcodeproj::Project.open(Location.pod_project_path)
		end

		def self.report_error(message)
			$stderr.puts "error: #{message}"
			exit 1
		end
	end

	module Installer

		def self.uninstall

			UI.title('Uninstalling Apollon for current Xcode project!')

			podfile = File.join(Dir.pwd, 'Podfile')
			unless File.exists?(podfile)
				UI.error "No 'Podfile' found in current directory!"
				exit 1
			end

			podfile_contents = File.read(podfile)
			if podfile_contents[/require\s+'apollon'/].nil?
				UI.error "Apollon is not installed!"
				exit 1
			end

			# remove podfile hook
			UI.notice('Remove podfile hook')
			podfile_contents[/require\s+'apollon'\s+Apollon::Installer\.install\(installer\)/] = ''
			File.open(podfile, 'w') do |file|
				file.puts podfile_contents
			end

			pods_project_path = File.join(Dir.pwd, 'Pods', 'Pods.xcodeproj')
			pods_project = Xcodeproj::Project.open(pods_project_path)
			apollon_target = pods_project.targets.find do |target| target.name == APOLLON end

			# remove dependency
			UI.notice('Remove dependency')
			pods_project.targets.each do |target|
				target_dependency = target.dependency_for_target(apollon_target)
				target_dependency.remove_from_project unless target_dependency.nil?
			end unless apollon_target.nil?

			# remove configuration
			UI.notice('Remove configuration')
			apollon_target.build_configurations.each do |configuration|
				configuration.remove_from_project
			end unless apollon_target.nil?

			unless apollon_target.nil?

				apollon_target.build_configuration_list.remove_from_project

				# remove compile sources
				UI.notice('Remove dummy source build file')
				apollon_target.source_build_phase.clear

				# remove product reference
				UI.notice('Remove product reference')
				apollon_target.product_reference.remove_from_project

				# remove target
				UI.notice('Remove apollon target')
				apollon_target.remove_from_project

				# remove apollonfile reference
				UI.notice('Remove Apollonfile reference')
				apollonfile_ref = pods_project.main_group["Apollonfile"]
				unless apollonfile_ref.nil?
					apollonfile_ref.remove_from_project
				end
			end

			# remove apollon file
			UI.notice('Remove Apollonfile')
			apollonfile = File.join(pods_project.project_dir, 'Apollonfile')
			if File.exists?(apollonfile)
				FileUtils.remove_entry(apollonfile)
			end

			# remove targets support files & reference (dummy source)
			UI.notice('Remove targets support files & reference')
			apollon_group_in_support_files = pods_project["Targets Support Files"]["Apollon"]
			unless apollon_group_in_support_files.nil?
				apollon_dir_in_support_files = apollon_group_in_support_files.real_path.to_path
				if Dir.exists?(apollon_dir_in_support_files)
					FileUtils.remove_dir(apollon_dir_in_support_files)
				end
				apollon_group_in_support_files.remove_from_project
			end

			# add all compile sources as before
			UI.notice('Add all compile sources as before')
			pods_project.targets.each do |target|

				next unless target.source_build_phase.files.empty?
				next if (target.name.start_with?('Pods-') || target.name == APOLLON)
				next unless target.source_build_phase.files.empty?

				project_dir = File.join(Dir.pwd, 'Pods')
				Apollon::RuntimeMethod.recover_compile_source_content(target, pods_project)
			end unless apollon_target.nil?

			UI.done
			pods_project.save
		end

		# execute when pod install
		def self.install(installer)

			UI.title('Installing Apollon to current Xcode project!')
			pods_project = installer.pods_project

			# disable deterministic_uuids
			UI.notice('Disable deterministic_uuids')
			Pod::Installer::InstallationOptions.defaults[:deterministic_uuids] = false

			# use legacy build system (temporarily)
			UI.notice('Using legacy build system')
			user_project_path = Pathname.new(installer.aggregate_targets.map(&:user_project_path).compact.uniq.first)
			user_workspace_setting_path = [
				user_project_path.dirname.to_path,
				user_project_path.basename('.xcodeproj').to_path + '.xcworkspace',
				'xcuserdata',
				%x(whoami).strip + '.xcuserdatad',
				'WorkspaceSettings.xcsettings'
			].join('/')

			if File.exists?(user_workspace_setting_path)
				workspace_setting_plist = CFPropertyList::List.new(:file => user_workspace_setting_path)
				workspace_setting_hash = CFPropertyList.native_types(workspace_setting_plist.value)
				workspace_setting_hash['BuildSystemType'] = 'Original'
				workspace_setting_plist.value = CFPropertyList.guess(workspace_setting_hash)
				workspace_setting_plist.save(user_workspace_setting_path, CFPropertyList::List::FORMAT_BINARY)
			else
				File.open(user_workspace_setting_path, 'w') do |file|
					file.puts "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
					file.puts "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">"
					file.puts "<plist version=\"1.0\">"
					file.puts " <dict>"
					file.puts "   <key>BuildSystemType</key>"
					file.puts "   <string>Original</string>"
					file.puts " </dict>"
					file.puts "</plist>"
				end
			end

			# create apollon target
			UI.notice('Create Apollon target')
			group = pods_project.targets.first.product_reference.parent
			deployment_target = pods_project.build_configuration_list.build_configurations.first.build_settings['IPHONEOS_DEPLOYMENT_TARGET']
			apollon_target = pods_project.new_target(:static_library, APOLLON, :ios, deployment_target, group)

			# copy [check pods manifest.lock] scripts to Apollon target
			UI.notice('Copy [Check Pods Manifest.lock] scripts to Apollon target')
			manifest_script = apollon_target.new_shell_script_build_phase('[Apollon] Check Pods Manifest.lock')
			manifest_script.show_env_vars_in_log = '0'
			manifest_script.shell_script = StringIO.open do |str|
				str.puts "diff \"${SRCROOT}/../Podfile.lock\" \"${SRCROOT}/Manifest.lock\" > /dev/null"
				str.puts 'if [ $? != 0 ] ; then'
				str.puts "  echo \"error: The sandbox is not in sync with the Podfile.lock. Run 'pod install' or update your CocoaPods installation.\" >&2"
				str.puts '  exit 1'
				str.puts 'fi'
				str.string
			end

			# add cache script
			UI.notice('Add cache script')
			sync_script = apollon_target.new_shell_script_build_phase("[#{APOLLON}] Sync")
			sync_script.show_env_vars_in_log = '0'
			sync_script.shell_script = StringIO.open do |str|
				str.puts 'PATH=~/.rbenv/shims:$PATH'
				str.puts 'apollon --cache'
				str.string
			end

			# add script in Pod-<TargetName>
			UI.notice("Add script in 'Pod-' prefixed target")
			dummy_target = pods_project.targets.find do |target| target.name.start_with?('Pods-') end
			sync_back_script = dummy_target.new_shell_script_build_phase("[Apollon] Collecting Libraries")
			sync_back_script.show_env_vars_in_log = '0'
			sync_back_script.shell_script = StringIO.open do |str|
				str.puts 'PATH=~/.rbenv/shims:$PATH'
				str.puts 'apollon --sync_back'
				str.string
			end

			# add dummy source
			UI.notice("Add dummy source")
			apollon_dir_in_support_files = File.join(pods_project.path.parent, 'Target Support Files', APOLLON)
			FileUtils.mkdir_p(apollon_dir_in_support_files)
			apollon_dummy_file = File.join(apollon_dir_in_support_files, "#{APOLLON}-dummy.m")
			File.open(apollon_dummy_file, 'w+') do |file|
				file.puts '#import <Foundation/Foundation.h>'
				file.puts "@interface #{APOLLON}_Dummy : NSObject"
				file.puts '@end'
				file.puts "@implementation #{APOLLON}_Dummy"
				file.puts '@end'
			end

			support_files_group = pods_project['Targets Support Files']
			apollon_group_in_support_files = support_files_group.new_group(APOLLON, apollon_dir_in_support_files)
			dummy_source_reference = apollon_group_in_support_files.new_reference(apollon_dummy_file)
			apollon_target.source_build_phase.add_file_reference(dummy_source_reference)

			# add dependency
			UI.notice("Add dependencies")
			pods_project.targets.each do |target|
				next if target.name == APOLLON
				target.add_dependency(apollon_target)
			end

			#save podspecs
			UI.notice("Save podspecs")
			podspecs_dir = File.join(installer.pods_project.project_dir, 'Local Podspecs')
			FileUtils.remove_dir(podspecs_dir)
			FileUtils.mkdir_p(podspecs_dir)

			installer.pod_targets.each do |pod_target|
				spec = pod_target.specs.first.root
				File.open(File.join(podspecs_dir, "#{spec.name}.podspec.json"), 'w+') do |file|
					file.puts JSON.pretty_generate(spec.to_hash)
				end
			end

			# save compile sources
			UI.notice("Save compile sources")
			source_mapping_dir = File.join(pods_project.project_dir, 'Source Mappings')
			if Dir.exists?(source_mapping_dir)
				FileUtils.remove_dir(source_mapping_dir)
			end
			FileUtils.mkdir_p(source_mapping_dir)

			pods_project.targets.each do |target|
				next if (target.name == APOLLON || target.name.start_with?('Pods-'))
				cs_mapping = Array.new
				target.source_build_phase.files.each do |build_file|
					unless build_file.settings.nil?
						compile_flag = build_file.settings['COMPILER_FLAGS']
					end
					uuid = build_file.file_ref.uuid
					cs_mapping << (compile_flag.nil? ? uuid : {uuid => compile_flag})
				end
				source_mapping_file = File.join(source_mapping_dir, "#{target.name}.cs.json")
				File.open(source_mapping_file, 'w') do |mapping_file|
					mapping_json = JSON.pretty_generate(cs_mapping)
					mapping_file.write(mapping_json)
				end
			end

			# add or update apollonfile
			UI.notice('Add or update Apollonfile')
			apollonfile = File.join(pods_project.path.parent, "#{APOLLON}file")
			apollonfile_exists = File.exists?(apollonfile)
			spec_state = installer.analysis_result.podfile_state
			apollonfile_need_update = !(spec_state.deleted + spec_state.added).empty?

			apollonfile_ref = pods_project.new_file(apollonfile)
			apollonfile_ref.explicit_file_type = 'text.plist.xml'
			return if apollonfile_exists && !apollonfile_need_update

			apollonfile_hash = Hash.new
			if apollonfile_exists

				plist = CFPropertyList::List.new(:file => apollonfile)
				apollonfile_hash = CFPropertyList.native_types(plist.value)
				spec_state.added.each do |pod_name|
					apollonfile_hash[pod_name] = false
				end
				spec_state.deleted.each do |pod_name|
					apollonfile_hash.delete(pod_name)
				end
			else
				pods_project.targets.each do |target|
					next if target.name == APOLLON || target.name.start_with?('Pods-')
					apollonfile_hash[target.name] = false
				end
			end

			plist = CFPropertyList::List.new
			plist.value = CFPropertyList.guess(apollonfile_hash)
			plist.save(apollonfile, CFPropertyList::List::FORMAT_BINARY)
			UI.done
		end

		def self.setup

			# check podfile
			podfile = File.join(Dir.pwd, 'Podfile')
			unless File.exists?(podfile)
				UI.error "No 'Podfile' found in current directory!"
				exit 1
			end

			# check apollon installed
			podfile_contents = File.read(podfile)
			unless podfile_contents['Apollon::Installer.install(installer)'].nil?
				UI.error 'Script has been installed!'
				exit 0
			end

			# install script
			UI.notice('Install Apollon Scripts!')
			if ::Pod::Podfile.from_file(podfile).instance_variable_get(:@post_install_callback).nil?
				File.open(podfile, 'a+') do |file|
					file.puts
					file.puts "post_install do |installer|"
					file.puts "  require 'apollon'"
					file.puts "  Apollon::Installer.install(installer)"
					file.puts "end"
					file.puts
				end
			else
				podfile_contents[/post_install\s+do\s+\|installer\|/] = StringIO.open do |str|
					str.puts "post_install do |installer|"
					str.puts "  require 'apollon'"
					str.puts "  Apollon::Installer.install(installer)"
					str.string
				end
				File.open(podfile, 'w') do |file|
					file.puts podfile_contents
				end
			end

			# run pod install
			UI.notice('Run pod install')
			system('pod install')
		end
	end
end

# main
ARGV.options do |opt|

	opt.banner = 'Usage: apollon [option]'
	opt.version = Apollon::VERSION
	opt.program_name = Apollon::APOLLON

	opt.on('--cache', 'sync apollon libraries to xcode') do
		Apollon::RuntimeMethod.synchronize_apollon_and_xcode
	end

	opt.on('--sync_back', 'collecting libraries to apollon') do
		Apollon::RuntimeMethod.collect_libraries_from_xcode
	end

	opt.on('--setup', 'install apollon for current Xcode project') do
		Apollon::Installer.setup
	end

	opt.on('--remove', 'uninstall apollon of current Xcode project') do
		Apollon::Installer.uninstall
	end

	opt.on('--clean', 'clean all apollon cached libraries') do
		Apollon::Cache.clean
	end

	opt.on('--clean-old', 'clean old apollon cached libraries') do
		Apollon::Cache.clean_old
	end

	opt.on_tail('-h', '--help', 'show all available options') do
		puts opt
	end
opt.parse!
end