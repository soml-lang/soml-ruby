# frozen_string_literal: true

# Tests for `SOML.format`, ported from soml-js's `test/format.ts`.
#
# The golden cases write a tab as `→`, to keep the layout readable. Every valid conformance case must format to a fixed point with the same value and the same comments, and so must the same document with other spacing and with comments, line breaks, and trailing commas added.

require_relative 'test_helper'

class TestFormat < Minitest::Test
	ROOT = File.join(__dir__, 'conformance')
	VALID_CASES = Dir.glob('valid/**/*.soml', base: ROOT).reject { it.end_with?('.canonical.soml', '.formatted.soml') }.sort
	INVALID_CASES = Dir.glob('invalid/**/*.soml', base: ROOT).sort

	# The text of each comment as the formatter writes it: without trailing spaces and tabs on each line, and with runs of blank lines in a block comment collapsed to one.
	def comment_texts(text)
		tree = SOML::Tree.new(text)

		tree.comments.map do |comment|
			lines = tree.source.byteslice(comment.start, comment.finish - comment.start).split("\n", -1).map { it.rstrip(" \t") }
			lines.reject.with_index { |line, index| line.empty? && index.positive? && lines[index - 1].empty? }.join("\n")
		end
	end

	def assert_format(input, expected)
		formatted = SOML.format(input)
		assert_equal expected, formatted.tr("\t", '→')
		assert_same_value SOML.parse(input), SOML.parse(formatted)
		assert_equal formatted, SOML.format(formatted)
	end

	# A document as the parts that the layout may not change, in source order: punctuation, and the opaque ranges of comments, scalars, and keys with their `:`. The gaps between them hold only spaces, tabs, and line breaks.
	def split_layout(text)
		tree = SOML::Tree.new(text)
		source = tree.source
		opaque = tree.comments.map { [it.start, it.finish, it.type] }
		stack = [tree.body]

		until stack.empty?
			node = stack.pop

			case node.type
			when :object
				node.members.each do |member|
					opaque << [member.key.start, member.key.finish + 1, :key]
					stack << member.value
				end
			when :array
				stack.concat(node.elements)
			else
				opaque << [node.start, node.finish, :scalar]
			end
		end

		opaque.sort!
		parts = []
		gaps = []
		index = 0
		gap_start = 0

		until index >= source.bytesize
			if opaque.first&.first == index
				start, finish, type = opaque.shift
				gaps << source.byteslice(gap_start, start - gap_start)
				parts << [type, source.byteslice(start, finish - start)]
				index = gap_start = finish
			elsif " \t\n".include?(source.byteslice(index, 1))
				index += 1
			else
				gaps << source.byteslice(gap_start, index - gap_start)
				parts << [:punctuator, source.byteslice(index, 1)]
				index = gap_start = index + 1
			end
		end

		gaps << source.byteslice(gap_start, source.bytesize - gap_start)
		[parts, gaps]
	end

	def join_layout(parts, gaps)
		gaps.first + parts.each_with_index.map { |(_, text), index| text + gaps[index + 1] }.join
	end

	# The same document with other spaces and tabs between its parts. Line breaks are kept.
	def change_spacing(parts, gaps, random)
		join_layout(parts, gaps.map { |gap| gap.split("\n", -1).map { ['', '', ' ', "\t", " \t "].sample(random:) }.join("\n") })
	end

	# The same value with comments and line breaks added between the parts, and the trailing comma toggled in some brackets.
	def change_layout(parts, gaps, random)
		parts = parts.map(&:dup)

		gaps = gaps.each_with_index.map do |gap, index|
			next gap if random.rand < 0.6

			# A comma must be on the line of the item before it, so no line break outside a comment goes before one, even with comments between them.
			before_comma = parts[index..].find { |(type, _)| type != :block }&.last == ','
			same_line = [' ', "/* added #{index} */", "/* added #{index}\n */"]
			addition = (before_comma ? same_line : [*same_line, "\n", "\n\n", "# added #{index}\n"]).sample(random:)

			# Text directly after a line comment would be part of it, so the addition goes on the next line.
			index.positive? && parts[index - 1].first == :line ? "#{gap}\n#{addition}" : "#{addition}#{gap}"
		end

		parts.each_with_index do |(type, text), index|
			next unless type == :punctuator && (text == ']' || text == '}') && random.rand < 0.5

			last = parts[0...index].rfind { |candidate| candidate.first != :line && candidate.first != :block }

			if last.last == ','
				last[1] = ''
			elsif last.last != '[' && last.last != '{'
				last[1] = "#{last.last},"
			end
		end

		join_layout(parts, gaps)
	end

	VALID_CASES.each_with_index do |name, case_index|
		define_method("test_conformance_#{name.delete_suffix('.soml')}") do
			text = File.binread(File.join(ROOT, name))
			formatted = SOML.format(text)

			assert_same_value SOML.parse(text), SOML.parse(formatted), 'The value changed.'
			assert_equal formatted, SOML.format(formatted), 'Formatting again changed the text.'
			assert_equal comment_texts(text), comment_texts(formatted), 'A comment changed.'

			canonical = File.binread(File.join(ROOT, name.sub(/\.soml\z/, '.canonical.soml'))).force_encoding(Encoding::UTF_8)
			assert_equal canonical, SOML.format(canonical), 'Canonical form is already formatted.'

			parts, gaps = split_layout(text)
			random = Random.new(case_index)

			3.times do
				respaced = change_spacing(parts, gaps, random)
				assert_equal formatted, SOML.format(respaced), "Spaces and tabs between tokens changed the output, for #{respaced.inspect}"

				changed = change_layout(parts, gaps, random)
				changed_formatted = SOML.format(changed)
				assert_same_value SOML.parse(text), SOML.parse(changed_formatted), "The value changed, for #{changed.inspect}"
				assert_equal changed_formatted, SOML.format(changed_formatted), "Formatting again changed the text, for #{changed.inspect}"
				assert_equal comment_texts(changed), comment_texts(changed_formatted), "A comment changed, for #{changed.inspect}"
			end
		end
	end

	INVALID_CASES.each do |name|
		define_method("test_conformance_#{name.delete_suffix('.soml')}") do
			text = File.binread(File.join(ROOT, name))
			expected = assert_raises(SOML::ParseError) { SOML.parse(text) }
			error = assert_raises(SOML::ParseError) { SOML.format(text) }
			assert_equal [expected.reason, expected.line, expected.column], [error.reason, error.line, error.column]
		end
	end

	def test_only_takes_a_string
		error = assert_raises(TypeError) { SOML.format(1) }
		assert_equal 'no implicit conversion of Integer into String', error.message
		assert_raises(TypeError) { SOML.format(BasicObject.new) }
	end

	def test_reads_the_source_as_parse_reads_it
		assert_equal "a: 'é'\n", SOML.format("a:   'é'".b)
		assert_equal "a: 'é'\n", SOML.format("a:   'é'".encode(Encoding::UTF_16LE))
		assert_equal Encoding::UTF_8, SOML.format('a: 1'.encode(Encoding::US_ASCII)).encoding
	end

	def test_does_not_change_or_freeze_the_source
		source = +'a:   1'
		formatted = SOML.format(source)
		assert_equal 'a:   1', source
		refute_predicate formatted, :frozen?
	end

	def test_keeps_non_ascii_text_in_place
		assert_format("# Café ☕\n'nöme': 'ü' # 😀\nb: [\n'é', \"ж\"]", "# Café ☕\n'nöme': 'ü' # 😀\nb: [\n→'é'\n→\"ж\"\n]\n")
	end

	def test_a_block_string_in_a_deep_object
		input = "#{'a: {' * 99}b: '''\n x\n '''#{'}' * 99}"
		formatted = SOML.format(input)
		assert_includes formatted, "#{"\t" * 99}b:\n#{"\t" * 100}'''\n#{"\t" * 100}x\n#{"\t" * 100}'''\n"
		assert_same_value SOML.parse(input), SOML.parse(formatted)
	end

	# The deepest indentation: a member of a braced container 100 levels deep, whose value is on a line of its own after a comment, one level deeper.
	def test_a_value_after_a_comment_in_the_deepest_container
		input = "#{"{\nk: " * 99}{\nk: # c\n'''\nx\n'''\n}#{"\n}" * 99}"
		formatted = SOML.format(input)
		assert_includes formatted, "#{"\t" * 100}k: # c\n#{"\t" * 101}'''\n#{"\t" * 101}x\n#{"\t" * 101}'''\n"
		assert_equal formatted, SOML.format(formatted)
		assert_same_value SOML.parse(input), SOML.parse(formatted)

		input = "#{"{\nk: " * 99}{\nk: # c\n1\n}#{"\n}" * 99}"
		assert_includes SOML.format(input), "#{"\t" * 100}k: # c\n#{"\t" * 101}1\n"
	end

	# The deepest indentation of all: every value is after a comment, so every container is two levels deeper than the one that holds it.
	def test_every_value_after_a_comment_in_the_deepest_document
		input = "#{"{\nk: # c\n" * 99}{\nk: # c\n'''\nx\n'''\n}#{"\n}" * 99}"
		formatted = SOML.format(input)
		assert_includes formatted, "#{"\t" * 199}k: # c\n#{"\t" * 200}'''\n#{"\t" * 200}x\n#{"\t" * 200}'''\n"
		assert_equal 200, formatted.lines.map { it[/\A\t*/].length }.max
		assert_equal formatted, SOML.format(formatted)
		assert_same_value SOML.parse(input), SOML.parse(formatted)
	end

	def test_an_invalid_document_raises_the_parse_error_of_parse
		expected = parse_error('a: b')
		error = assert_raises(SOML::ParseError) { SOML.format('a: b') }
		assert_equal [expected.reason, expected.line, expected.column], [error.reason, error.line, error.column]
	end

	# One tab per level, and every member and item of a container that spans lines on its own line.
	def test_one_tab_per_level_and_every_member_and_item_of_a_container_that_spans_lines_on_its_own_line
		assert_format("a: {b: 1, c: [1,\n2], d: {}, e: [\n]}", "a: {\n→b: 1\n→c: [\n→→1\n→→2\n→]\n→d: {}\n→e: []\n}\n")
	end

	# A container on one line stays on one line.
	def test_a_container_on_one_line_stays_on_one_line
		assert_format('a: {b: 1,  c: [1,2,], d: {}}', "a: {b: 1, c: [1, 2], d: {}}\n")
		assert_format("m: [\n[1,0], [0, 1]\n]", "m: [\n→[1, 0]\n→[0, 1]\n]\n")
		assert_format('a: [[ /* x */ ], 1]', "a: [[/* x */], 1]\n")
		assert_format('a: {b: [1, /* end */ ], c: 2 , }', "a: {b: [1 /* end */], c: 2}\n")
		assert_format('[1, 2]  # Tail', "[1, 2] # Tail\n")
	end

	# A line break inside a comment or a block string splits a container.
	def test_a_line_break_inside_a_comment_or_a_block_string_splits_a_container
		assert_format("a: [1, /* x\ny */ 2]", "a: [\n→1\n→/* x\ny */ 2\n]\n")
		assert_format("a: [1, '''\nx\n''']", "a: [\n→1\n→'''\n→x\n→'''\n]\n")
	end

	# A braced document stays braced, and a top-level array is indented.
	def test_a_braced_document_stays_braced_and_a_top_level_array_is_indented
		assert_format('{a: 1}', "{a: 1}\n")
		assert_format("{\na: 1}", "{\n→a: 1\n}\n")
		assert_format("[1,\n[2]]", "[\n→1\n→[2]\n]\n")
	end

	# One space after the colon.
	def test_one_space_after_the_colon
		assert_format("a:1\nb:    2", "a: 1\nb: 2\n")
	end

	# A value on the line after its key moves up.
	def test_a_value_on_the_line_after_its_key_moves_up
		assert_format("a:\n\t1", "a: 1\n")
	end

	# Spelling is kept.
	def test_spelling_is_kept
		assert_format('\'b c\': [0xFF, 1_000, 90m, "x", \'y\', 2026-09-19T16:00:00+02:00]', "'b c': [0xFF, 1_000, 90m, \"x\", 'y', 2026-09-19T16:00:00+02:00]\n")
	end

	# Trailing whitespace is removed, and runs of blank lines become one.
	def test_trailing_whitespace_is_removed_and_runs_of_blank_lines_become_one
		assert_format("\n\n# Header   \n\n\n\na: 1  \n\n\n\nb: 2\n\n\n", "# Header\n\na: 1\n\nb: 2\n")
	end

	# No blank line directly inside brackets.
	def test_no_blank_line_directly_inside_brackets
		assert_format("a: [\n\n1,\n\n2,\n\n]", "a: [\n→1\n\n→2\n]\n")
		assert_format("a: {\n\nb: 1\n\n}", "a: {\n→b: 1\n}\n")
		assert_format("[\n\n# c\n1]", "[\n→# c\n→1\n]\n")
	end

	# A comma at the start of a line is an error.
	def test_a_comma_at_the_start_of_a_line_is_an_error
		assert_raises(SOML::ParseError) { SOML.format("[1\n,\n2]") }
		assert_raises(SOML::ParseError) { SOML.format("{a: 1\n, b: 2}") }
	end

	# A comment at the end of a line stays there.
	def test_a_comment_at_the_end_of_a_line_stays_there
		assert_format("a: [1, # One\n2 # Two\n]", "a: [\n→1 # One\n→2 # Two\n]\n")
		assert_format("a: [1 /* One */\n]", "a: [\n→1 /* One */\n]\n")
	end

	# Every comma in a container that spans lines is removed, and a trailing comma on one line.
	def test_every_comma_in_a_container_that_spans_lines_is_removed_and_a_trailing_comma_on_one_line
		assert_format("a: [\n\t1,\n\t2,\n]\nb: {\n\tc: 1,\n\td: [3, 4,],\n}", "a: [\n→1\n→2\n]\nb: {\n→c: 1\n→d: [3, 4]\n}\n")
		assert_format("[1, 2\n3,\n4,]", "[\n→1\n→2\n→3\n→4\n]\n")
	end

	# Items separated by line breaks are already formatted.
	def test_items_separated_by_line_breaks_are_already_formatted
		assert_format("a: [\n\t1\n\t2\n]\nb: {\n\tc: 1 # c\n\td: 2\n}", "a: [\n→1\n→2\n]\nb: {\n→c: 1 # c\n→d: 2\n}\n")
		assert_format("{\na: 1\nb: 2\n}", "{\n→a: 1\n→b: 2\n}\n")
	end

	# A block comment before a value on the same line stays in front of it.
	def test_a_block_comment_before_a_value_on_the_same_line_stays_in_front_of_it
		assert_format("[1, /* x */ 2\n]", "[\n→1\n→/* x */ 2\n]\n")
		assert_format("a: [1 /* a */, /* b */ 2\n]", "a: [\n→1 /* a */\n→/* b */ 2\n]\n")
		assert_format("[1, /* a */ /* b */ 2\n]", "[\n→1\n→/* a */ /* b */ 2\n]\n")
		assert_format('[1 /* a */, /* b */ 2, /* c */]', "[1 /* a */, /* b */ 2 /* c */]\n")
		assert_format('/* a */ /* b */ a: 1', "/* a */ /* b */ a: 1\n")
	end

	# A comment on its own line stays on its own line.
	def test_a_comment_on_its_own_line_stays_on_its_own_line
		assert_format("a: [\n1,\n# Note\n2,\n# End\n]", "a: [\n→1\n→# Note\n→2\n→# End\n]\n")
	end

	# A comment after the opening bracket stays on its line.
	def test_a_comment_after_the_opening_bracket_stays_on_its_line
		assert_format("a: [ # c\n1]", "a: [ # c\n→1\n]\n")
		assert_format("a: { # only\n}", "a: { # only\n}\n")
		assert_format("{#\n\n1: []}", "{ #\n→1: []\n}\n")
	end

	# An empty collection with comments is laid out like a non-empty one.
	def test_an_empty_collection_with_comments_is_laid_out_like_a_non_empty_one
		assert_format("a: [\n# only\n]", "a: [\n→# only\n]\n")
	end

	# A comment after the colon.
	def test_a_comment_after_the_colon
		assert_format('a: /* c */ 1', "a: /* c */ 1\n")
		assert_format("a: # c\n1", "a: # c\n→1\n")
		assert_format("a: # c\n{b: 1}", "a: # c\n→{b: 1}\n")
		assert_format("a: # c\n{\nb: 1}", "a: # c\n→{\n→→b: 1\n→}\n")
		assert_format("a:\n# c\n1", "a:\n→# c\n→1\n")
	end

	# A line break inside a block comment after the colon does not move the value.
	def test_a_line_break_inside_a_block_comment_after_the_colon_does_not_move_the_value
		assert_format("a: /* x\ny */ {b: 1}", "a: /* x\ny */ {b: 1}\n")
	end

	# The lines of a block comment keep their indentation.
	def test_the_lines_of_a_block_comment_keep_their_indentation
		assert_format("/* a\n   b */ key: 1", "/* a\n   b */ key: 1\n")
	end

	# Runs of blank lines in a block comment collapse to one.
	def test_runs_of_blank_lines_in_a_block_comment_collapse_to_one
		assert_format("/* a\n\n\n\n   b   \n*/\nkey: 1", "/* a\n\n   b\n*/\nkey: 1\n")
	end

	# Only spaces and tabs are trailing whitespace in a comment.
	def test_only_spaces_and_tabs_are_trailing_whitespace_in_a_comment
		assert_format("# x \u{A0}\t\na: 1", "# x \u{A0}\na: 1\n")
		assert_format("a: 1 #\u{FEFF}", "a: 1 #\u{FEFF}\n")
	end

	# A block string begins on the line after its key, and its delimiters and content line up.
	def test_a_block_string_begins_on_the_line_after_its_key_and_its_delimiters_and_content_line_up
		assert_format("pool: {\n    description: '''\n        one\n          two\n\n        ''',\n}", "pool: {\n→description:\n→→'''\n→→one\n→→  two\n\n→→'''\n}\n")
		assert_format("a: [\n'''\nx\n'''\n]", "a: [\n→'''\n→x\n→'''\n]\n")
		assert_format("a:\n\t'''\n\tx\n\t'''", "a:\n→'''\n→x\n→'''\n")
	end

	# Trailing whitespace in a block string is content.
	def test_trailing_whitespace_in_a_block_string_is_content
		assert_format("a: '''\n\tx  \n\t'''", "a:\n→'''\n→x  \n→'''\n")
	end

	# A blank line between comments is kept.
	def test_a_blank_line_between_comments_is_kept
		assert_format("a: [\n1,\n# One\n\n# Two\n2,\n]", "a: [\n→1\n→# One\n\n→# Two\n→2\n]\n")
		assert_format("# One\n\n# Two\na: 1", "# One\n\n# Two\na: 1\n")
	end

	# A top-level array with comments.
	def test_a_top_level_array_with_comments
		assert_format("# Head\n[1, # One\n2] # Tail", "# Head\n[\n→1 # One\n→2\n] # Tail\n")
	end

	# A comment after the closing bracket stays on its line.
	def test_a_comment_after_the_closing_bracket_stays_on_its_line
		assert_format("a: [1,\n2] /* t */\nb: 3", "a: [\n→1\n→2\n] /* t */\nb: 3\n")
	end

	# A multi-line block comment inside an array.
	def test_a_multi_line_block_comment_inside_an_array
		assert_format("a: [1,\n/* one\n  two */\n2]", "a: [\n→1\n→/* one\n  two */\n→2\n]\n")
	end

	# A block string after a comment that follows the colon.
	def test_a_block_string_after_a_comment_that_follows_the_colon
		assert_format("a: # c\n\t'''\n\tx\n\t'''", "a: # c\n→'''\n→x\n→'''\n")
		assert_format("a: /* c */ '''\n\tx\n\t'''", "a: /* c */\n→'''\n→x\n→'''\n")
	end

	# A blank line inside a block string is left as it is.
	def test_a_blank_line_inside_a_block_string_is_left_as_it_is
		assert_format("a: '''\n  x\n   \n  y\n  '''", "a:\n→'''\n→x\n   \n→y\n→'''\n")
	end
end
