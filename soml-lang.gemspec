# frozen_string_literal: true

require_relative 'lib/soml/version'

Gem::Specification.new do |spec|
	spec.name = 'soml-lang'
	spec.version = SOML::VERSION
	spec.authors = ['Sindre Sorhus']
	spec.email = ['sindresorhus@gmail.com']
	spec.summary = 'Read and write SOML, a config format for humans'
	spec.description = 'A strict parser and a generator for SOML that keeps member order or writes canonical form, with exact integers, instants, and durations, and an error message that says what is wrong and where. With a formatter, an editor that keeps comments and layout, and a syntax tree for linters.'
	spec.homepage = 'https://github.com/soml-lang/soml-ruby'
	spec.license = 'MIT'
	spec.required_ruby_version = '>= 4.0'

	spec.metadata = {
		'source_code_uri' => spec.homepage,
		'bug_tracker_uri' => "#{spec.homepage}/issues",
		'changelog_uri' => "#{spec.homepage}/releases",
		'rubygems_mfa_required' => 'true'
	}

	spec.files = Dir['lib/**/*.rb', 'sig/**/*.rbs', 'license', 'readme.md']
	spec.require_paths = ['lib']
end
