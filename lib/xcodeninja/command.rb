module XcodeNinja
  require 'xcodeproj'
  require 'colored'
  require 'claide'
  require 'pp' # for debug

  REFERENCE_FRAMEWORKS = %w|UIKit Security ImageIO GoogleMobileAds CoreGraphics|

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
      ninja_targets = {}
      xcodeproj.targets.each {|target|
        build_configurations = target.build_configurations
        build_configurations.each {|bc|
          bs = bc.build_settings
          lib_dirs = expand(bs['LIBRARY_SEARCH_PATHS'])
          framework_dirs = expand(bs['FRAMEWORK_SEARCH_PATHS'])
          target_header_dirs = expand(bs['HEADER_SEARCH_PATHS'])

          lib_options = lib_dirs.map { |dir| "-L#{dir}" }.join(' ')
          framework_options = (framework_dirs.map { |f| "-F#{f}" } + REFERENCE_FRAMEWORKS.map{ |f| "-framework #{f}" }).join(' ')
          header_options = (header_dirs + target_header_dirs).map{ |dir| "-I./#{dir}" }.join(' ')

        }
      }
      unless @xcodeproj_path
        fail Informative, 'Please specify Xcode project.'
      end

      target.build_phases.each{|phase|
        case phase
        when Xcodeproj::Project::Object::PBXResourceBuildPhase
          resource_build_phase(phase)
        when Xcodeproj::Project::Object::PBXSourceBuildPhase
          source_build_phase(phase)
        else
          fail Informative, "Don't support the phase #{phase.class.name}."
        end
      }
    end

    private

    def resource_build_phase(target, phase)
      build_dir = xxxx
      phase.files_references.each {|file|
        case file
        when Xcodeproj::Project::Object::PBXFileReference
          files = [file]
        when Xcodeproj::Project::Object::PBXVariantGroup
          files = file.files
        else
          fail Informative, "Don't support the file #{file.class.name}."
        end

        files.each{ |file|
          local_path = File.join(file.parents.map{|group| group.path}.select{|path| path}, file.path)
          remote_path = File.join(RESOURCES_DIR, file.path)

          #p remote_path, local_path
          if file.path.end_with?(".storyboard")
              remote_path += "c"
              desc remote_path
              file remote_path => local_path do |t|
                  sh "ibtool --errors --warnings --notices --module #{APP_NAME} --target-device iphone --minimum-deployment-target 9.0 --output-format human-readable-text --compilation-directory tmp/#{File.dirname(local_path)} #{local_path}"
                  sh "ibtool --errors --warnings --notices --module #{APP_NAME} --target-device iphone --minimum-deployment-target 9.0 --output-format human-readable-text --link #{RESOURCES_DIR} tmp/#{local_path}c"
              end
          else
              dir = File.dirname(remote_path)
              directory dir
              desc remote_path
              file remote_path => [local_path, dir] do |t|
                  cp_r local_path, remote_path
              end
          end

          resources << remote_path
        }
      }
      infoplist = File.join(BUNDLE_DIR, "Info.plist")
      resources << infoplist
      directory File.dirname(BUNDLE_DIR)

      desc "Info.plist"
      # TODO fix Info.plist path
      file infoplist => File.join(APP_NAME, "Resources/Info.plist") do |t|
          cp t.prerequisites[0], t.name
      end
    end

    def source_build_phase(phase)
    end

    def expand(value, type=nil)
      # TODO: Expand $(TARGET_NAME) etc.
      if value.kind_of?(Enumerable)
        value.reject {|v|
          v == '$(inherited)'
        }.map {|v|
          expand(v)
        }
      else
        case type
        when :bool
          value == 'YES'
        else
          value.gsub(/$\(([A-Za-z0-9_])\)/) {|m|
            case m[1]
            when 'PROJECT_DIR'
              xcodeproj_dir
            else
              fail Informative, "Not support for #{m[1]}"
            end
          }
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
