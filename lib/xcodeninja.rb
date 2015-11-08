module XcodeNinja
  require 'claide'

  class PlainInformative < StandardError
    include CLAide::InformativeError
  end

  class Informative < PlainInformative
    def message
      super !~ /\[!\]/ ? "[!] #{super}\n".red : super
    end
  end

  require 'xcodeninja/gem_version'

  autoload :Command, 'xcodeninja/command'
end
