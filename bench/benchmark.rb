# frozen_string_literal: true

# Measures this gem on the shared benchmark fixtures in `bench/fixtures`, and compares it with the common JSON and TOML gems on the `.json` and `.toml` files that hold the same data.
#
#   bundle exec ruby --yjit bench/benchmark.rb
#
# The JSON and TOML gems other than `json` are compared when they are installed: `bundle config set --local with benchmark && bundle install`. A time is CPU time, the median of several samples, so that other work on the machine counts less than it would in wall-clock time.

require_relative '../lib/soml'
require 'json'

FIXTURES = Dir[File.join(__dir__, 'fixtures', '*.soml')].to_h { [File.basename(it, '.soml'), File.binread(it)] }

def cpu_time
	start = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
	yield
	Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - start
end

# The CPU time of one call of the block: the median of 11 samples, after a warm-up that lets YJIT compile the hot paths. A sample repeats a fast call until it takes 20 ms, because the clock is too coarse for one call of a few microseconds.
def measure
	5.times { yield }
	repeats = 1
	repeats *= 2 while cpu_time { repeats.times { yield } } < 0.02
	samples = Array.new(11) { cpu_time { repeats.times { yield } } / repeats }
	samples.sort[samples.length / 2]
end

def optional(name)
	require name
	true
rescue LoadError
	false
end

mode = if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
	'YJIT'
elsif defined?(RubyVM::ZJIT) && RubyVM::ZJIT.enabled?
	'ZJIT'
else
	'interpreter'
end

puts "#{RUBY_DESCRIPTION} (#{mode})"
puts
puts 'This gem on each fixture, in microseconds:'
puts
puts format('%-12s %8s %10s %10s %10s %10s %10s', '', 'size', 'parse', 'generate', 'format', 'edit', 'parse_tree')

FIXTURES.each do |name, text|
	value = SOML.parse(text)

	# A change of the first member, as a tool that updates one setting makes.
	path = [value.keys.first]
	times = [
		measure { SOML.parse(text) },
		measure { SOML.generate(value) },
		measure { SOML.format(text) },
		measure { SOML.edit(text, path, 'edited') },
		measure { SOML.parse_tree(text) }
	]

	puts format('%-12s %6.1fKB %10.1f %10.1f %10.1f %10.1f %10.1f', name, text.bytesize / 1000.0, *times.map { it * 1_000_000 })
end

# Each format reads its own file of the fixture, and writes back the data that it read.
formats = {
	'SOML (this gem)' => ['soml', ->(value) { SOML.generate(value) }, ->(text) { SOML.parse(text) }],
	'JSON (json)' => ['json', ->(value) { JSON.pretty_generate(value) }, ->(text) { JSON.parse(text) }]
}

formats['JSON (oj)'] = ['json', ->(value) { Oj.dump(value, mode: :compat, indent: 2) }, ->(text) { Oj.load(text, mode: :compat) }] if optional('oj')
formats['TOML (tomlib)'] = ['toml', ->(value) { Tomlib.dump(value) }, ->(text) { Tomlib.load(text) }] if optional('tomlib')
formats['TOML (toml-rb)'] = ['toml', ->(value) { TomlRB.dump(value) }, ->(text) { TomlRB.parse(text) }] if optional('toml-rb')
formats['TOML (perfect_toml)'] = ['toml', ->(value) { PerfectTOML.generate(value) }, ->(text) { PerfectTOML.parse(text) }] if optional('perfect_toml')

# tomlrb cannot write TOML.
formats['TOML (tomlrb)'] = ['toml', nil, ->(text) { Tomlrb.parse(text) }] if optional('tomlrb')

FIXTURES.each_key do |fixture|
	puts
	puts "Every format on #{fixture}, in microseconds:"
	puts
	puts format('%-20s %8s %10s %10s', '', 'size', 'parse', 'generate')

	formats.each do |name, (extension, generate, parse)|
		text = File.binread(File.join(__dir__, 'fixtures', "#{fixture}.#{extension}"))
		value = parse.(text)
		parse_time = measure { parse.(text) }
		generate_time = generate && measure { generate.(value) }
		puts format('%-20s %6.1fKB %10.1f %10s', name, text.bytesize / 1000.0, parse_time * 1_000_000, generate_time ? format('%.1f', generate_time * 1_000_000) : '')
	end
end
