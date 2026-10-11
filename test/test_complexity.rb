# frozen_string_literal: true

# Every input shape takes linear time: 8 times the input must take far less than 64 times as long, which a quadratic step would. The time is the CPU time of this process, so that other work on the machine does not count.

require_relative 'test_helper'

class TestComplexity < Minitest::Test
	SMALL = 20_000
	FACTOR = 8

	# A linear step gives a ratio of about 8, and a quadratic one about 64. The margin covers timer noise, garbage collection, and a larger heap, which makes each allocation slower.
	MAXIMUM_RATIO = 28

	# The time of one run. A fast run is repeated for at least 2 ms and averaged, because the timer and the noise are too coarse for one run of a few microseconds.
	def elapsed
		GC.start
		start = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
		count = 0

		loop do
			yield
			count += 1
			total = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - start
			return total / count if total >= 0.002
		end
	end

	# `build` makes an input of a given size, and the block runs it.
	def assert_linear(name, build, &run)
		small = build.(SMALL)
		large = build.(SMALL * FACTOR)

		# Warm up, so that the first run does not pay for loading and compiling.
		run.(small)

		# Other work on the machine can still slow one run down, through the caches it shares, so a ratio over the limit is measured again, up to 3 times. A quadratic step is over the limit every time.
		ratio = small_time = large_time = nil

		3.times do
			small_time = elapsed { run.(small) }
			large_time = elapsed { run.(large) }
			ratio = large_time / small_time
			break if ratio < MAXIMUM_RATIO
		end

		assert_operator ratio, :<, MAXIMUM_RATIO, "#{name}: #{FACTOR} times the input took #{ratio.round(1)} times as long (#{(small_time * 1000).round(2)} ms, then #{(large_time * 1000).round(2)} ms)"
	end

	def assert_parses_linearly(name, &build)
		assert_linear(name, build) { SOML.parse(it) }
	end

	def assert_fails_linearly(name, &build)
		assert_linear(name, build) do |input|
			error = assert_raises(SOML::ParseError) { SOML.parse(input) }
			error.code_frame
		end
	end

	def test_valid_shapes
		assert_parses_linearly('long literal string') { "a: '#{'x' * it}'" }
		assert_parses_linearly('long escaped string') { "a: \"#{'x\\n' * it}\"" }
		assert_parses_linearly('long non-ASCII string') { "a: '#{'é' * it}'" }
		assert_parses_linearly('many Unicode escapes') { "a: \"#{'\\u{1f600}' * it}\"" }
		assert_parses_linearly('many members') { (0...(it / 4)).map { "k#{it}: #{it}" }.join("\n") }
		assert_parses_linearly('one-line array of strings') { "[#{"'a', \"b\"," * it}]" }
		assert_parses_linearly('one-line array of numbers') { "[#{'1.5, 0x1F, 1e5, 30s, 2026-09-19T14:00:00Z, ' * (it / 8)}]" }
		assert_parses_linearly('many block comments') { "[#{'/* c */ 1,' * it}]" }
		assert_parses_linearly('long line comment') { "a: 1 # #{'x' * it}" }
		assert_parses_linearly('long block comment') { "/* #{'x' * it} */ a: 1" }
		assert_parses_linearly('long block string') { "a: '''\n#{"\tline\n" * it}\t'''" }
		assert_parses_linearly('long escaped block string') { "a: \"\"\"\n#{"\tline\\t\\u{e9}\n" * it}\t\"\"\"" }
		assert_parses_linearly('long whitespace run') { "a:#{' ' * it}1#{"\n" * it}" }
		assert_parses_linearly('hexadecimal with leading zeros') { "a: 0x#{'0' * it}FF" }
		assert_parses_linearly('integer with underscores') { "a: 0b#{'0_' * it}1" }
		assert_parses_linearly('float with a long fraction') { "a: 0.#{'0' * 200}#{'1' * it}" }
		assert_parses_linearly('float with many zeros') { "a: 1.#{'0' * it}1" }
		assert_parses_linearly('duration with a long fraction') { "a: 1.#{'0' * it}s" }
		assert_parses_linearly('float with a long exponent of zero') { "a: 0.0e#{'1' * it}" }
		assert_parses_linearly('block string with a long blank line') { "a: '''\n#{' ' * it}\nx\n'''" }
		assert_parses_linearly('deep arrays, many times') { "[#{"#{'[' * 50}#{']' * 50},\n" * (it / 100)}]" }
	end

	def test_error_shapes
		assert_fails_linearly('huge invalid number') { "a: #{'1' * it}x" }
		assert_fails_linearly('huge hexadecimal number with lowercase digits') { "a: 0x#{'1' * it}ff" }
		assert_fails_linearly('huge number with a leading zero and octal digits') { "a: 0#{'7' * it}" }
		assert_fails_linearly('huge number with leading zeros and a digit that is not octal') { "a: 0#{'0' * it}8" }
		assert_fails_linearly('huge integer') { "a: #{'1' * it}" }
		assert_fails_linearly('huge exponent') { "a: 1e#{'1' * it}" }
		assert_fails_linearly('huge negative exponent') { "a: 1e-#{'1' * it}" }
		assert_fails_linearly('huge duplicate key') { "#{'a' * it}: 1\n#{'a' * it}: 2" }
		assert_fails_linearly('huge invalid instant') { "a: 2026-09-19T#{'1' * it}" }
		assert_fails_linearly('huge duration') { "a: #{'1' * it}s" }
		assert_fails_linearly('unterminated string') { "a: 'x\n#{"b: 'y'\n" * it}" }
		assert_fails_linearly('error at the end of a long line') { "a: [#{'1, ' * it}x]" }
		assert_fails_linearly('error at the end of a non-ASCII document') { "#{"a#{rand(1 << 30)}: 'é'\n" * it}b: x" }
		assert_fails_linearly('duplicate key at the end') { "#{(0...it).map { "k#{it}: 1" }.join("\n")}\nk0: 2" }
		assert_fails_linearly('key that needs quotes') { "$#{'a' * it}: 1" }
		assert_fails_linearly('key with spaces') { "#{'a ' * it}: 1" }
		assert_fails_linearly('long key with many dots') { "#{'a.' * it}b: 1" }
		assert_fails_linearly('long key before a dot') { "#{'a' * it}.b: 1" }
		assert_fails_linearly('long key with many dots in braces') { "{x: 1, #{'a.' * it}b: 1}" }
		assert_fails_linearly('comment before the colon, then spaces') { "a/* c */#{' ' * it}: 1" }
		assert_fails_linearly('control character at the end') { "a: '#{'x' * it}\u0001'" }
		assert_fails_linearly('invalid UTF-8 at the end') { "a: '#{'é' * it}\xFF'".b }
		assert_fails_linearly('unterminated block comment') { "/* #{'x' * it}" }
		assert_fails_linearly('unterminated block string') { "a: '''\n#{"line\n" * it}" }
		assert_fails_linearly('long comment where a value was meant to start with "#"') { "a: ##{'x' * it}" }
		assert_fails_linearly('long number followed by a space and a unit') { "a: 1.#{'0' * it} ms" }
		assert_fails_linearly('unterminated block string with its delimiter at the end of the last line') { "a: '''\n#{"line\n" * it}x'''" }
	end

	def test_generate
		assert_linear('long array', ->(size) { Array.new(size) { |index| [index, index * 0.5, "s#{index}", nil] } }) { SOML.generate(it) }
		assert_linear('many keys', ->(size) { (0...size).to_h { ["k#{it}", it] } }) { SOML.generate(it) }
		assert_linear('long escaped string', ->(size) { {'a' => "x'\n" * size} }) { SOML.generate(it) }
		assert_linear('nested hashes', ->(size) { Array.new(size / 50) { (0...50).reduce(1) { |inner, _| {'a' => inner} } } }) { SOML.generate(it) }
	end

	# A tree holds several objects for every token, so the inputs are smaller, as in the JS reference's tests. Each shape has a path for `edit` to change.
	TREE_SHAPES = {
		'many members, each with a comment' => [->(size) { (0...(size / 16)).map { "k#{it}: #{it} # note" }.join("\n") }, ['k0']],
		'a one-line array' => [->(size) { "[#{"1, /* c */ 'a', " * (size / 16)}]" }, [0]],
		'many block strings' => [->(size) { (0...(size / 40)).map { "k#{it}: '''\n\t\tline\n\n\t\t'''" }.join("\n") }, ['k0']],
		'many blank lines between comments' => [->(size) { "a: [\n#{"# c\n\n\n" * (size / 16)}]" }, ['a', 0]],
		'a long line' => [->(size) { "a: '#{'é' * size}' # #{'x' * size}\nb: \"#{'\\n' * size}\"" }, ['b']],
		'a long block comment' => [->(size) { "/* #{"x\n\n\n  " * (size / 8)} */\na: 1" }, ['a']],
		'deep nesting, many times' => [->(size) { "[#{"#{'[' * 50}#{']' * 50},\n" * (size / 100)}]" }, [0, 0]],
		'deep objects, many times' => [->(size) { (0...(size / 200)).map { "k#{it}: #{'{a: ' * 40}1#{'}' * 40}" }.join("\n") }, ['k0', 'a', 'a']]
	}.freeze

	def test_format
		TREE_SHAPES.each do |name, (build, _)|
			assert_linear("format: #{name}", build) { SOML.format(it) }
		end

		assert_linear('format: a one-line array of many short items', ->(size) { "[#{'1,' * size}]" }) { SOML.format(it) }
		assert_linear('format: many block comments on one line after a member', ->(size) { "a: 1#{' /* c */' * (size / 2)}\nb: 2" }) { SOML.format(it) }
		assert_linear('format: many block comments on one line before an item', ->(size) { "[1,#{' /* c */' * (size / 2)}\n2]" }) { SOML.format(it) }
		assert_linear('format: many block comments on one line before a value', ->(size) { "a:#{' /* c */' * (size / 2)} 1" }) { SOML.format(it) }
		assert_linear('format: many items on one line, each after a comment', ->(size) { "[#{'/* c */ 1, ' * (size / 4)}]" }) { SOML.format(it) }
		assert_linear('format: a long run of spaces and commas', ->(size) { "[1#{' ' * size},#{"\t" * size}2]" }) { SOML.format(it) }
	end

	# A linter asks for the position of every node, and an autofix edits through a node.
	def test_parse_tree
		TREE_SHAPES.each do |name, (build, _)|
			assert_linear("parse_tree: #{name}", build) { SOML.parse_tree(it) }
		end

		positions = ->(size) { SOML.parse_tree((0...(size / 16)).map { "k#{it}: 'é' # note" }.join("\n")) }
		assert_linear('the position of every node', positions) { |tree| tree.each_node { tree.position(it.start) } }

		one_line = ->(size) { SOML.parse_tree("a: [#{(["'é'"] * (size / 16)).join(', ')}]") }
		assert_linear('the position of every node on one long non-ASCII line', one_line) { |tree| tree.each_node { tree.position(it.start) } }

		nested = ->(size) { "[#{"[#{'1, ' * 10}{a: [1, 2]}],\n" * (size / 32)}]" }
		assert_linear('edit through the last node', nested) { SOML.edit(it, SOML.parse_tree(it).body.elements.last.elements.last.members.first.value.elements.last, 3) }
	end

	def test_edit
		TREE_SHAPES.each do |name, (build, path)|
			assert_linear("edit: #{name}", build) { SOML.edit(it, path, 1) }
			assert_linear("edit: removing from #{name}", build) { SOML.edit(it, path, delete: true) }
		end

		assert_linear('edit: adding an item to a long one-line array', ->(size) { "[#{'1, ' * size}1]" }) { SOML.edit(it, [it.count(',') + 1], 2) }
		assert_linear('edit: removing an item in the middle of a long one-line array', ->(size) { "[#{'1, ' * size}1]" }) { SOML.edit(it, [it.count(',') / 2], delete: true) }

		members = ->(size, separator) { (0...(size / 32)).map { "c#{it}: 1#{separator}\n\n" }.join }
		assert_linear('edit: removing a member after many blank lines at the start of the document', ->(size) { "#{"\n" * (size / 32)}#{members.(size, '')}" }) { SOML.edit(it, ['c0'], delete: true) }
		assert_linear('edit: removing a member after many comments at the start of its container', ->(size) { "{#{' /* c */' * (size / 32)}\n#{members.(size, ',')}}" }) { SOML.edit(it, ['c0'], delete: true) }
		assert_linear('edit: removing a member after many blank lines at the start of its container', ->(size) { "{\n#{"\n" * (size / 32)}#{members.(size, ',')}}" }) { SOML.edit(it, ['c0'], delete: true) }
	end
end
