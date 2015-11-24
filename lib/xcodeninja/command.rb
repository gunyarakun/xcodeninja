module XcodeNinja
  require 'xcodeproj'
  require 'colored'
  require 'claide'
  require 'pp' # for debug

  REFERENCE_FRAMEWORKS = %w(UIKit Security ImageIO GoogleMobileAds CoreGraphics)

  class Command < CLAide::Command
    self.command = 'xcodeninja'
    self.version = VERSION
    self.arguments = [CLAide::Argument.new('PROJECT', false)]
    self.description = 'XcodeNinja lets you create build.ninja from Xcode projects.'

    def initialize(argv)
      self.xcodeproj_path = argv.shift_argument
      @output_path = Pathname(argv.shift_argument || '.')

      super

      unless self.ansi_output?
        String.send(:define_method, :colorize) { |string, _| string }
      end
    end

    def run
      unless @xcodeproj_path
        fail Informative, 'Please specify Xcode project.'
      end

      header_dirs = xcodeproj.main_group.recursive_children.select { |g| g.path && File.extname(g.path) == '.h' }.map{ |g|
        full_path = File.join((g.parents + [g]).map{ |group| group.path }.select{ |path| path })
        File.dirname(full_path)
      }.to_a.uniq

      xcodeproj.targets.each do |target|
        build_configurations = target.build_configurations
        build_configurations.each do |bc|
          bs = bc.build_settings
          lib_dirs = expand(bs['LIBRARY_SEARCH_PATHS'], :array)
          framework_dirs = expand(bs['FRAMEWORK_SEARCH_PATHS'], :array)
          target_header_dirs = expand(bs['HEADER_SEARCH_PATHS'], :array)

          lib_options = lib_dirs.map { |dir| "-L#{dir}" }.join(' ')
          framework_options = (framework_dirs.map { |f| "-F#{f}" } + REFERENCE_FRAMEWORKS.map{ |f| "-framework #{f}" }).join(' ')
          header_options = (header_dirs + target_header_dirs).map{ |dir| "-I./#{dir}" }.join(' ')

        end

        builds = target.build_phases.map do |phase|
          case phase
          when Xcodeproj::Project::Object::PBXResourcesBuildPhase
            resources_build_phase(target, phase)
          when Xcodeproj::Project::Object::PBXSourcesBuildPhase
            sources_build_phase(target, phase)
          when Xcodeproj::Project::Object::PBXFrameworksBuildPhase
            frameworks_build_phase(target, phase)
          when Xcodeproj::Project::Object::PBXShellScriptBuildPhase
            shell_script_build_phase(target, phase)
          else
            fail Informative, "Don't support the phase #{phase.class.name}."
          end
        end.flatten.compact

        File.open("#{target.name}.ninja.build", 'w:UTF-8') do |f|
          f.puts rules(target)
          f.puts ''
          builds.each do |b|
            f.puts "build #{b[:outputs].join(' ')}: #{b[:rule_name]} #{b[:inputs].join(' ')}"
            f.puts ''
          end
        end
      end
    end

    private

    def rules(target)
      # TODO: extract minimum-deployment-target from xcodeproj
      r = <<RULES
rule ibtool_compile
  command = ibtool --errors --warnings --notices --module #{target.product_name} --target-device iphone --minimum-deployment-target 9.0 --output-format human-readable-text --compilation-directory `dirname ${out}` ${in}

rule ibtool_link
  command = ibtool --errors --warnings --notices --module #{target.product_name} --target-device iphone --minimum-deployment-target 9.0 --output-format human-readable-text --link `dirname ${out}` ${in}

rule cp_r
  command = cp -r ${in} ${out}

rule file_packager
  command = python #{ENV['EMSCRIPTEN']}/tools/file_packager.py ${out} --preload #{build_dir(target)}@/ > #{build_dir(target)}/ManboData.js
RULES
      r
    end

    def build_dir(target)
      "build/#{target.name}"
    end

    def bundle_dir(target)
      "#{build_dir(target)}/Contents"
    end

    def resources_dir(target)
      "#{bundle_dir(target)}/Resources"
    end

    def data_path(target)
      "#{build_dir(target)}/#{target.product_name}.dat"
    end

    def resources_build_phase(target, phase)
      builds = []
      resources = []
      phase.files_references.each do |file|
        case file
        when Xcodeproj::Project::Object::PBXFileReference
          files = [file]
        when Xcodeproj::Project::Object::PBXVariantGroup
          files = file.files
        else
          fail Informative, "Don't support the file #{file.class.name}."
        end

        files.each do |file|
          local_path = File.join(file.parents.map{|group| group.path}.select{|path| path}, file.path)
          remote_path = File.join(resources_dir(target), file.path)

          #p remote_path, local_path
          if File.extname(file.path) == '.storyboard'
            remote_path += 'c'
            tmp_path = File.join('tmp', remote_path)
            builds << {
              :outputs => [tmp_path],
              :rule_name => 'ibtool_compile',
              :inputs => [local_path],
            }
            builds << {
              :outputs => [remote_path],
              :rule_name => 'ibtool_link',
              :inputs => [tmp_path],
            }
          else
            builds << {
              :outputs => [remote_path],
              :rule_name => 'cp_r',
              :inputs => [local_path],
            }
          end

          resources << remote_path
        end
      end
      infoplist = File.join(bundle_dir(target), 'Info.plist')
      resources << infoplist

      builds << {
        :outputs => [infoplist],
        :rule_name => 'cp_r',
        # TODO fix Info.plist path
        :inputs => [File.join(target.product_name, 'Resources/Info.plist')],
      }

      # UIKit bundle
      builds << {
        :outputs => ["#{build_dir(target)}/frameworks/UIKit.framework/"],
        :rule_name => 'cp_r',
        :inputs => ["#{ENV['EMSCRIPTEN']}/system/frameworks/UIKit.framework/Resources/"],
      }
      resources << "#{build_dir(target)}/frameworks/UIKit.framework/"

      builds << {
        :outputs => [data_path(target)],
        :rule_name => 'file_packager',
        :inputs => resources,
      }

      builds
    end

    def sources_build_phase(target, phase)
      # FIXME: Implement
    end

    def frameworks_build_phase(target, phase)
      # FIXME: Implement
    end

    def shell_script_build_phase(target, phase)
      # FIXME: Implement
    end

    def expand(value, type=nil)
      # TODO: Expand $(TARGET_NAME) etc.
      if value.kind_of?(Enumerable)
        value.reject do |v|
          v == '$(inherited)'
        end.map do |v|
          expand(v)
        end
      else
        case type
        when :bool
          value == 'YES'
        when :array
          if value.kind_of?(Array)
            value
          elsif value.nil?
            []
          else
            [value]
          end
        else
          if value.nil?
            nil
          else
            value.gsub(/$\(([A-Za-z0-9_])\)/) do |m|
              case m[1]
              when 'PROJECT_DIR'
                xcodeproj_dir
              else
                fail Informative, "Not support for #{m[1]}"
              end
          end
          end
        end
      end
    end

    def xcodeproj_path
      unless @xcodeproj_path
        fail Informative, 'Please specify Xcode project.'
      end
      @xcodeproj_path
    end

    def xcodeproj_dir
      unless @xcodeproj_dir
        fail Informative, 'Please specify Xcode project.'
      end
      @xcodeproj_dir
    end

    def xcodeproj_path=(path)
      @xcodeproj_path = path && Pathname.new(path).expand_path
      @xcodeproj_dir = File.dirname(@xcodeproj_path)
    end

    def xcodeproj
      @xcodeproj ||= Xcodeproj::Project.open(xcodeproj_path)
    end
  end
end
