module XcodeNinja
  require 'xcodeproj'
  require 'pathname'
  require 'colored'
  require 'claide'

  require 'pp' # for debug

  REFERENCE_FRAMEWORKS = %w(UIKit Security ImageIO GoogleMobileAds CoreGraphics)
  LINK_FRAMEWORKS = %w(UIKit Security ImageIO AudioToolbox CommonCrypto SystemConfiguration CoreGraphics QuartzCore AppKit CFNetwork OpenGLES Onyx2D CoreText)

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

      xcodeproj.targets.each do |target|
        target.build_configurations.each do |build_config|
          generate_ninja_build(xcodeproj, target, build_config)
        end
      end
    end

    private

    def generate_ninja_build(xcodeproj, target, build_config)
      builds = generate_build_rules(xcodeproj, target, build_config)
      write_ninja_build(target, build_config, builds)
    end

    def generate_build_rules(xcodeproj, target, build_config)
      target.build_phases.map do |phase|
        case phase
        when Xcodeproj::Project::Object::PBXResourcesBuildPhase
          resources_build_phase(xcodeproj, target, build_config, phase)
        when Xcodeproj::Project::Object::PBXSourcesBuildPhase
          sources_build_phase(xcodeproj, target, build_config, phase)
        when Xcodeproj::Project::Object::PBXFrameworksBuildPhase
          frameworks_build_phase(xcodeproj, target, build_config, phase)
        when Xcodeproj::Project::Object::PBXShellScriptBuildPhase
          shell_script_build_phase(xcodeproj, target, build_config, phase)
        else
          fail Informative, "Don't support the phase #{phase.class.name}."
        end
      end.flatten.compact
    end

    def write_ninja_build(target, build_config, builds)
      File.open("#{target.name}.#{build_config.name}.ninja.build", 'w:UTF-8') do |f|
        f.puts rules(target, build_config)
        f.puts ''
        builds.each do |b|
          f.puts "build #{b[:outputs].join(' ')}: #{b[:rule_name]} #{b[:inputs].join(' ')}"
          variables = b[:variables] || []
          variables.each do |k, v|
            f.puts "  #{k} = #{v}"
          end
          f.puts ''
        end
      end
    end

    def rules(target, build_config)
      # TODO: extract minimum-deployment-target from xcodeproj
      r = <<RULES
rule ibtool_compile
  command = ibtool --errors --warnings --notices --module #{target.product_name} --target-device iphone --minimum-deployment-target 9.0 --output-format human-readable-text --compilation-directory `dirname ${out}` ${in}

rule ibtool_link
  command = ibtool --errors --warnings --notices --module #{target.product_name} --target-device iphone --minimum-deployment-target 9.0 --output-format human-readable-text --link `dirname ${out}` ${in}

rule cc
  command = a2o ${cflags} -c ${source} -o ${out}

rule link
  command = llvm-link -o ${out} ${in}

rule cp_r
  command = cp -r ${in} ${out}

rule file_packager
  command = python #{ENV['EMSCRIPTEN']}/tools/file_packager.py ${target} --preload #{packager_target_dir(target, build_config)}@/ --js-output=${js_output}

rule emscripten_html
  command = EMCC_DEBUG=1 a2o -v -s TOTAL_MEMORY=402653184 ${framework_ref_options} ${lib_options} -s NATIVE_LIBDISPATCH=1 --emrun -o ${out} ${linked_objects} --pre-js ${pre_js} # --pre-js mem_check.js
RULES
      r
    end

    def build_dir(target, build_config)
      "build/#{target.name}/#{build_config.name}"
    end

    def packager_target_dir(target, build_config)
      "#{build_dir(target, build_config)}/package"
    end

    def bundle_dir(target, build_config)
      "#{packager_target_dir(target, build_config)}/Contents"
    end

    def framework_bundle_dir(target, build_config)
      "#{packager_target_dir(target, build_config)}/frameworks"
    end

    def resources_dir(target, build_config)
      "#{bundle_dir(target, build_config)}/Resources"
    end

    def objects_dir(target, build_config)
      "#{build_dir(target, build_config)}/objects"
    end

    def data_path(target, build_config)
      "#{build_dir(target, build_config)}/#{target.product_name}.dat"
    end

    def data_js_path(target, build_config)
      "#{build_dir(target, build_config)}/#{target.product_name}Data.js"
    end

    def html_path(target, build_config)
      "#{build_dir(target, build_config)}/#{target.product_name}.html"
    end

    def binary_path(target, build_config)
      "#{build_dir(target, build_config)}/#{target.product_name}.bc"
    end

    def resources_build_phase(_xcodeproj, target, build_config, phase)
      builds = []
      resources = []
      phase.files_references.each do |files_ref|
        case files_ref
        when Xcodeproj::Project::Object::PBXFileReference
          files = [files_ref]
        when Xcodeproj::Project::Object::PBXVariantGroup
          files = files_ref.files
        else
          fail Informative, "Don't support the file #{files_ref.class.name}."
        end

        files.each do |file|
          local_path = File.join(file.parents.map(&:path).select { |path| path }, file.path)
          remote_path = File.join(resources_dir(target, build_config), file.path)

          if File.extname(file.path) == '.storyboard'
            remote_path += 'c'
            tmp_path = File.join('tmp', remote_path)
            builds << {
              outputs: [tmp_path],
              rule_name: 'ibtool_compile',
              inputs: [local_path],
            }
            builds << {
              outputs: [remote_path],
              rule_name: 'ibtool_link',
              inputs: [tmp_path],
            }
          else
            builds << {
              outputs: [remote_path],
              rule_name: 'cp_r',
              inputs: [local_path],
            }
          end

          resources << remote_path
        end
      end

      infoplist = File.join(bundle_dir(target, build_config), 'Info.plist')
      resources << infoplist

      builds << {
        outputs: [infoplist],
        rule_name: 'cp_r',
        # TODO: fix Info.plist path
        inputs: [File.join(target.product_name, 'Resources/Info.plist')],
      }

      # UIKit bundle
      framework_resources = file_recursive_copy("#{ENV['EMSCRIPTEN']}/system/frameworks/UIKit.framework/Resources/", "#{framework_bundle_dir(target, build_config)}/UIKit.framework/Resources/")
      builds += framework_resources[:builds]
      resources += framework_resources[:outputs]

      # file_packager
      t = data_path(target, build_config)
      j = data_js_path(target, build_config)
      builds << {
        outputs: [t, j],
        rule_name: 'file_packager',
        inputs: resources,
        variables: {
          'target' => t,
          'js_output' => j,
        }
      }

      builds
    end

    def file_recursive_copy(in_dir, out_dir)
      builds = []
      outputs = []

      in_path = Pathname(in_dir)

      in_path.find do |path|
        next unless path.file?

        rel_path = path.relative_path_from(in_path)
        output_path = File.join(out_dir, rel_path.to_s)
        builds << {
          outputs: [output_path],
          rule_name: 'cp_r',
          inputs: [path.to_s],
        }
        outputs << output_path
      end

      {
        builds: builds,
        outputs: outputs,
      }
    end

    def sources_build_phase(xcodeproj, target, build_config, phase)
      # FIXME: Implement
      builds = []
      objects = []

      header_dirs = xcodeproj.main_group.recursive_children.select { |g| g.path && File.extname(g.path) == '.h' }.map do |g|
        full_path = File.join((g.parents + [g]).map(&:path).select { |path| path })
        File.dirname(full_path)
      end.to_a.uniq

      # build settings
      bs = build_config.build_settings
      lib_dirs = expand(bs['LIBRARY_SEARCH_PATHS'], :array)
      framework_dirs = expand(bs['FRAMEWORK_SEARCH_PATHS'], :array)
      target_header_dirs = expand(bs['HEADER_SEARCH_PATHS'], :array)

      lib_options = lib_dirs.map { |dir| "-L#{dir}" }.join(' ')
      framework_dir_options = framework_dirs.map { |f| "-F#{f}" }.join(' ')
      framework_ref_options = REFERENCE_FRAMEWORKS.map { |f| "-framework #{f}" }.join(' ')
      header_options = (header_dirs + target_header_dirs).map { |dir| "-I./#{dir}" }.join(' ')

      # FIXME: fetch pch path from xcodeproj
      prefix_pch = "#{target.product_name}/Prefix.pch"

      # build sources
      phase.files_references.each do |file|
        source_path = File.join(file.parents.map(&:path).select { |path| path }, file.path)
        object = File.join(objects_dir(target, build_config), source_path.gsub(/\.[A-Za-z0-9]+$/, '.o'))

        objects << object

        settings = file.build_files[0].settings
        # TODO: set default option
        file_opt = '-s FULL_ES2=1 -O0 -DGL_GLEXT_PROTOTYPES=1 -D__IPHONE_OS_VERSION_MIN_REQUIRED=70000 -D__CC_PLATFORM_IOS=1 -DDEBUG=1 -DCD_DEBUG=1 -DCOCOS2D_DEBUG=1 -DCC_TEXTURE_ATLAS_USE_VAO=0 -Wno-warn-absolute-paths '
        if settings && settings.key?('COMPILER_FLAGS')
          file_opt += expand(settings['COMPILER_FLAGS'], :array).join(' ')
        end
        file_opt += ' -fobjc-arc' unless file_opt =~ /-fno-objc-arc/

        cflags = [framework_dir_options, framework_ref_options, header_options, lib_options, file_opt].join(' ')

        builds << {
          outputs: [object],
          rule_name: 'cc',
          inputs: [source_path, prefix_pch],
          variables: {
            'cflags' => "#{cflags} -include #{prefix_pch}",
            'source' => source_path,
          }
        }
      end

      # stubs
      # FIXME: remove
      %w(AidAd_dummy.m Parse_dummy.m).each do |source_path|
        object = File.join(objects_dir(target, build_config), source_path.gsub(/\.[A-Za-z0-9]+$/, '.o'))
        objects << object

        cflags = [framework_dir_options, framework_ref_options, header_options, lib_options].join(' ')

        builds << {
          outputs: [object],
          rule_name: 'cc',
          inputs: [source_path, prefix_pch],
          variables: {
            'cflags' => "#{cflags} -include #{prefix_pch}",
            'source' => source_path,
          }
        }
      end

      # link
      builds << {
        outputs: [binary_path(target, build_config)],
        rule_name: 'link',
        inputs: objects
      }

      # executable
      builds << {
        outputs: [html_path(target, build_config)],
        rule_name: 'emscripten_html',
        inputs: [data_js_path(target, build_config), binary_path(target, build_config)],
        variables: {
          'pre_js' => data_js_path(target, build_config),
          'linked_objects' => binary_path(target, build_config),
          'framework_ref_options' => LINK_FRAMEWORKS.map { |f| "-framework #{f}" }.join(' '),
          'lib_options' => `PKG_CONFIG_LIBDIR=#{ENV['EMSCRIPTEN']}/system/lib/pkgconfig:#{ENV['EMSCRIPTEN']}/system/local/lib/pkgconfig pkg-config freetype2 --libs`.strip,
        }
      }

      builds
    end

    def frameworks_build_phase(xcodeproj, target, build_config, phase)
      # FIXME: Implement
    end

    def shell_script_build_phase(xcodeproj, target, build_config, phase)
      # FIXME: Implement
    end

    def expand(value, type = nil)
      if value.is_a?(Array)
        value = value.reject do |v|
          v == '$(inherited)'
        end

        value.map do |v|
          expand(v)
        end
      else
        case type
        when :bool
          value == 'YES'
        when :array
          if value.nil?
            []
          else
            [expand(value)]
          end
        else
          if value.nil?
            nil
          else
            value.gsub(/\$\([A-Za-z0-9_]+\)/) do |m|
              case m
              when '$(PROJECT_DIR)'
                xcodeproj_dir
              when '$(SDKROOT)'
                # FIXME: currently ignores
                ''
              when '$(DEVELOPER_FRAMEWORKS_DIR)'
                # FIXME: currently ignores
                ''
              else
                fail Informative, "Not support for #{m}"
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
