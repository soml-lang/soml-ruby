# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rake/testtask'

Rake::TestTask.new(:test) do |task|
	task.libs << 'test'
	task.test_files = FileList['test/**/test_*.rb']
	task.warning = true
end

task default: :test
