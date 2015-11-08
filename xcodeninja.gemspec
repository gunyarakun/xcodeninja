# -*- encoding: utf-8 -*-
require File.expand_path('../lib/xcodeninja/gem_version', __FILE__)

Gem::Specification.new do |s|
  s.name     = 'xcodeninja'
  s.version  = XcodeNinja::VERSION
  s.license  = 'MIT'
  s.email    = 'tasuku-s-github@titech.ac'
  s.homepage = 'https://github.com/cocoapods/xcodeninja'
  s.authors  = ['Tasuku SUENAGA a.k.a. gunyarakun']

  s.summary     = 'Create and modify Xcode projects from Ruby.'
  s.description = %(
    xcodeninja lets you create build.ninja from Xcode projects.
  ).strip.gsub(/\s+/, ' ')

  s.files         = %w( README.md LICENSE ) + Dir['lib/**/*.rb']

  s.executables   = %w( xcodeninja )
  s.require_paths = %w( lib )

  s.add_runtime_dependency 'colored', '~> 1.2'
  s.add_runtime_dependency 'claide', '~> 0.9.1'
  s.add_runtime_dependency 'xcodeproj', '~> 0.28.2'

  ## Make sure you can build the gem on older versions of RubyGems too:
  s.rubygems_version = '1.6.2'
  if s.respond_to? :required_rubygems_version=
    s.required_rubygems_version = Gem::Requirement.new('>= 0')
  end
  s.required_ruby_version = '>= 2.2.0'
  s.specification_version = 3 if s.respond_to? :specification_version
end
