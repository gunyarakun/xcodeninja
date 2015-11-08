module XcodeNinja
  require 'xcodeproj'
  require 'colored'
  require 'claide'

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
      puts xcodeproj
    end

    private

    def xcodeproj_path
      unless @xcodeproj_path
        fail Informative, 'Please specify Xcode project.'
      end
      @xcodeproj_path
    end

    def xcodeproj_path=(path)
      @xcodeproj_path = path && Pathname.new(path).expand_path
    end

    def xcodeproj
      @xcodeproj ||= Xcodeproj::Project.open(xcodeproj_path)
    end
  end
end
