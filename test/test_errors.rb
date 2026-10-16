# frozen_string_literal: true

# Unit tests for `SOML::ParseError`, ported from soml-js's `test/errors.ts`. The reasons, lines, and columns are the same as in JS.
#
# Where Ruby differs: `ParseError` is a `SOML::Error`, not a `SyntaxError`. `message` is the reason and the position on one line, and the code frame is in `code_frame` and `detailed_message`. `offset` counts characters (code points), where JS counts UTF-16 code units. The JS suite that runs the invalid conformance cases is in `test_conformance.rb`.

require_relative 'test_helper'
require 'json'

class TestErrors < Minitest::Test
	BIDI_CONTROLS = ["\u061C", "\u200E", "\u200F", "\u202A", "\u202B", "\u202C", "\u202D", "\u202E", "\u2066", "\u2067", "\u2068", "\u2069"].freeze

	# ParseError

	def test_is_a_soml_error_and_a_standard_error
		error = parse_error('')
		assert_kind_of SOML::Error, error
		assert_kind_of StandardError, error
		assert_equal 'SOML::ParseError', error.class.name
	end

	def test_has_the_reason_the_position_and_a_code_frame
		error = parse_error("a: 1\nb: nope\n")
		assert_equal "Unexpected “nope”. A string value must be quoted, as in 'nope'", error.reason
		assert_equal 2, error.line
		assert_equal 4, error.column
		assert_equal 8, error.offset
		assert_equal "  1 | a: 1\n> 2 | b: nope\n    |    ^", error.code_frame
	end

	def test_the_message_is_the_reason_and_the_position_on_one_line
		error = parse_error("a: 1\nb: nope\n")
		assert_equal "#{error.reason} at line 2, column 4", error.message
	end

	def test_the_detailed_message_adds_the_code_frame
		error = parse_error("a: 1\nb: nope\n")
		assert_equal "#{error.message} (SOML::ParseError)\n\n#{error.code_frame}", error.detailed_message(highlight: false)
		assert_includes error.full_message(highlight: false), "#{error.message} (SOML::ParseError)\n\n#{error.code_frame}"
	end

	def test_terminal_and_bidirectional_controls_in_duplicate_keys_are_sanitized_in_the_reason_and_message
		["\u009B", *BIDI_CONTROLS].each do |character|
			key = "\\u{#{character.ord.to_s(16)}}admin"
			error = parse_error("\"#{key}\": 1\n\"#{key}\": 2")
			assert_equal "Duplicate key \"\uFFFDadmin\"", error.reason
			assert_equal "#{error.reason} at line 2, column 1", error.message
			refute_includes error.detailed_message, character
		end
	end

	def test_terminal_and_bidirectional_controls_in_unknown_escapes_are_sanitized_in_the_reason_and_message
		["\u009B", *BIDI_CONTROLS].each do |character|
			error = parse_error("a: \"\\#{character}\"")
			assert error.reason.start_with?("Unknown escape “\\\uFFFD”"), error.reason
			assert_equal "#{error.reason} at line 1, column 5", error.message
			refute_includes error.detailed_message, character
		end
	end

	# Positions

	def test_line_and_column_are_1_based
		error = parse_error('}')
		assert_equal [1, 1, 0], [error.line, error.column, error.offset]
	end

	def test_a_column_counts_code_points_so_an_emoji_is_one_column
		source = "a: '😀😀' x"
		error = parse_error(source)
		assert_equal 9, error.column
		# JS counts UTF-16 code units and gives 10.
		assert_equal 8, error.offset
		assert_equal 'x', source[error.offset]
	end

	def test_the_offset_is_a_character_index_into_the_source
		source = "a: 'é日😀'\nb: '\u{10FFFF}' nope"
		error = parse_error(source)
		assert_equal [2, 8], [error.line, error.column]
		assert_equal 'nope', source[error.offset, 4]
	end

	def test_the_offset_counts_characters_in_a_binary_source_too
		source = "a: 'é😀'\nb: nope"
		error = parse_error(source.b)
		assert_equal [2, 4], [error.line, error.column]
		assert_equal 'nope', source[error.offset, 4]
	end

	def test_the_offset_of_invalid_utf8_counts_the_characters_before_it
		{
			"a: 'é😀\xFF'" => ['Invalid UTF-8 byte 0xFF', 1, 7, 6],
			"a: 'éé\xC3('" => ['Invalid UTF-8 byte 0xC3', 1, 7, 6],
			"a: 1\nb: 'é\xFF'" => ['Invalid UTF-8 byte 0xFF', 2, 6, 10]
		}.each do |source, expected|
			[source, source.b].each do |each_source|
				error = parse_error(each_source)
				assert_equal expected, [error.reason, error.line, error.column, error.offset], each_source.inspect
			end
		end
	end

	def test_a_tab_is_one_column
		assert_equal 6, parse_error("\t\ta: nope").column
	end

	def test_an_error_on_a_later_line
		error = parse_error("a: 1\n\n\n# c\nb: 2\nc: nope")
		assert_equal [6, 4], [error.line, error.column]
	end

	def test_an_error_at_the_end_of_the_document_points_past_the_last_character
		error = parse_error('a:')
		assert_equal 'Expected a value, but reached the end of the document', error.reason
		assert_equal 3, error.column
		assert_equal 2, error.offset
	end

	def test_an_unterminated_container_points_at_its_opening
		error = parse_error('a: [1, 2')
		assert_equal 'Unterminated array: expected “]”', error.reason
		assert_equal [1, 4], [error.line, error.column]
	end

	def test_an_error_right_after_a_line_break_is_on_the_next_line
		error = parse_error("a: 1\n}")
		assert_equal [2, 1], [error.line, error.column]
	end

	def test_an_error_on_a_line_break_character_is_on_the_line_it_ends
		error = parse_error("{a\n: 1}")
		assert_equal [2, 1, 3], [error.offset, error.line, error.column]
	end

	def test_an_unterminated_string_points_at_its_opening_quote
		error = parse_error("a: 'x\n")
		assert_equal [1, 4], [error.line, error.column]
	end

	def test_the_position_of_a_duplicate_key_is_the_second_key
		error = parse_error("{\n\ta: 1,\n\ta: 2,\n}")
		assert_equal [3, 2], [error.line, error.column]
	end

	def test_a_dot_in_a_key_points_at_the_dot
		[
			['a.b: 1', 1, 2],
			['example.com: 1', 1, 8],
			["3.14: 'x'", 1, 2],
			["'a'.b: 1", 1, 4],
			["a.'b': 1", 1, 2],
			['{a.b: 1}', 1, 3],
			['x: {a.b: 1}', 1, 6],
			['[{a.b: 1}]', 1, 4],
			["a: 1\n\tb.c: 2", 2, 3],
			['.a: 1', 1, 1]
		].each do |source, line, column|
			error = parse_error(source)
			assert_equal [line, column], [error.line, error.column], source
		end
	end

	def test_an_unterminated_block_comment_points_at_its_opening
		error = parse_error("a: 1\n\n  /* x\n\n")
		assert_equal [3, 3], [error.line, error.column]
	end

	def test_a_position_after_astral_characters_on_earlier_lines
		error = parse_error("a: '😀😀😀'\nb: nope")
		assert_equal [2, 4], [error.line, error.column]
	end

	# Code frame

	def test_the_code_frame_shows_up_to_two_lines_before_the_error
		assert_equal "  2 | b: 2\n  3 | c: 3\n> 4 | d: nope\n    |    ^", parse_error("a: 1\nb: 2\nc: 3\nd: nope").code_frame
	end

	def test_the_code_frame_aligns_the_gutter_for_multi_digit_line_numbers
		source = "#{Array.new(9) { "k#{it}: #{it}" }.join("\n")}\nk9: nope"
		assert_equal "   8 | k7: 7\n   9 | k8: 8\n> 10 | k9: nope\n     |     ^", parse_error(source).code_frame
	end

	def test_the_code_frame_keeps_tabs_before_the_caret_so_it_lines_up
		assert_equal "  1 | a: {\n> 2 | \t\tb: nope,\n    | \t\t   ^", parse_error("a: {\n\t\tb: nope,\n}").code_frame
	end

	def test_an_empty_line_is_shown_without_trailing_whitespace
		assert_equal "  1 | a: 1\n  2 |\n> 3 | b: nope\n    |    ^", parse_error("a: 1\n\nb: nope").code_frame
		assert_equal "  1 |\n> 2 | b: nope\n    |    ^", parse_error("\nb: nope").code_frame
	end

	def test_the_code_frame_of_an_empty_document
		assert_equal "> 1 |\n    | ^", parse_error('').code_frame
	end

	def test_a_long_line_is_clipped_around_the_error
		line, pointer = parse_error("a: [#{'1, ' * 200}nope, #{'1, ' * 200}]").code_frame.split("\n")
		assert_operator line.length, :<, 120
		assert line.start_with?('> 1 | …'), line
		assert line.end_with?('…'), line
		assert_equal line.index('nope'), pointer.index('^')
	end

	def test_a_long_line_clipped_at_its_start_keeps_the_pointer_right
		line, pointer = parse_error("a: nope #{'x' * 300}").code_frame.split("\n")
		refute line.start_with?('> 1 | …'), line
		assert_equal line.index('nope'), pointer.index('^')
	end

	def test_a_long_line_clipped_at_its_end_keeps_the_pointer_right
		assert_equal "> 1 | …#{'x' * 94}' nope\n    | #{' ' * 97}^", parse_error("a: '#{'x' * 300}' nope").code_frame
	end

	def test_a_long_context_line_is_clipped_too
		assert_equal "  1 | a: '#{'x' * 96}…\n> 2 | b: nope\n    |    ^", parse_error("a: '#{'x' * 300}'\nb: nope").code_frame
	end

	def test_clipping_a_long_line_of_astral_characters_keeps_whole_characters_and_the_pointer_right
		4.times do |padding|
			line, pointer = parse_error("a: '#{'x' * padding}#{'😀' * 40}' nope #{'😀' * 100}").code_frame.split("\n")
			assert_predicate line, :valid_encoding?, "padding #{padding}"
			assert_equal line.index('nope'), pointer.index('^'), "padding #{padding}"
		end
	end

	def test_the_first_and_last_astral_characters
		["\u{10000}", "\u{10FFFF}"].each do |character|
			assert_equal 10, parse_error("a: '#{character * 3}' nope").column

			4.times do |padding|
				line, pointer = parse_error("a: '#{'x' * padding}#{character * 40}' nope #{character * 100}").code_frame.split("\n")
				assert_predicate line, :valid_encoding?, "padding #{padding}"
				assert_equal line.index('nope'), pointer.index('^'), "padding #{padding}"
			end
		end
	end

	# JS cuts a quoted token at 40 UTF-16 code units, and backs off by one rather than split a surrogate pair.
	def test_a_quoted_token_is_cut_short_like_in_js
		key = "#{'x' * 39}😀yy"
		error = parse_error("\"#{key}\": 1\n\"#{key}\": 2")
		assert_predicate error.reason, :valid_encoding?
		assert_equal "Duplicate key \"#{'x' * 39}…\"", error.reason

		key = '😀' * 30
		assert_equal "Duplicate key \"#{'😀' * 20}…\"", parse_error("\"#{key}\": 1\n\"#{key}\": 2").reason
	end

	def test_characters_a_terminal_would_act_on_are_replaced_in_the_code_frame
		{
			"a: \"\e[2J\"" => "> 1 | a: \"\uFFFD[2J\"",
			"a: 'x\ry'" => "> 1 | a: 'x\uFFFDy'",
			"a: \u202Ex" => "> 1 | a: \uFFFDx"
		}.each do |source, line|
			assert_equal line, parse_error(source).code_frame.split("\n").first, source.inspect
		end

		assert_equal "> 1 | a: 'x\uFFFDy'\n    |      ^", parse_error("a: 'x\ry'").code_frame
	end

	# JS shows a lone surrogate as U+FFFD. In Ruby it is invalid UTF-8, and the frame shows the text before it.
	def test_the_code_frame_of_invalid_utf8_shows_the_text_before_the_bad_byte
		assert_equal "> 1 | a: '\n    |     ^", parse_error("a: '\xED\xA0\x80'").code_frame
		assert_equal "  1 | a: 1\n> 2 | b: 'é\n    |      ^", parse_error("a: 1\nb: 'é\xFF'".b).code_frame
	end

	def test_tabs_are_kept_in_the_code_frame
		assert_equal "> 1 | \ta: nope\n    | \t   ^", parse_error("\ta: nope").code_frame
	end

	def test_every_bidirectional_control_is_sanitized_in_the_code_frame
		BIDI_CONTROLS.each do |character|
			error = parse_error("'#{character}admin': 1\n'#{character}admin': 2")
			assert_equal "  1 | '\uFFFDadmin': 1\n> 2 | '\uFFFDadmin': 2\n    | ^", error.code_frame
		end
	end

	def test_the_code_frame_comes_from_bytes_the_same_way
		assert_equal "  1 | a: 1\n> 2 | b: nope\n    |    ^", parse_error("a: 1\nb: nope".b).code_frame
	end

	def test_the_code_frame_is_utf8
		assert_equal Encoding::UTF_8, parse_error("a: 1\nb: nope".b).code_frame.encoding
		assert_equal Encoding::UTF_8, parse_error("a: 'é'\nb: nope".encode(Encoding::UTF_16LE)).code_frame.encoding
	end

	# Reasons

	REASONS = [
		['', 'A document must contain an object or an array, but this one is empty'],
		['# only a comment', 'A document must contain an object or an array, but this one is empty'],
		['5', 'A bare value is not a document. A document is an object or an array, so write it as `key: value` or `[value]`'],
		['2026-09-19T14:00:00Z', 'A bare value is not a document. A document is an object or an array, so write it as `key: value` or `[value]`'],
		["'hello'", 'A bare value is not a document. A document is an object or an array, so write it as `key: value` or `[value]`'],
		["true\nb: 1", 'Expected “:” after the key'],
		['2026-09-19T14:1x', 'Invalid number “1x”. A string value must be quoted, as in \'1x\''],
		['a: 1, b: 2', 'Top-level entries are separated by line breaks, not commas. Use braces for a one-line object'],
		['a: 1 b: 2', 'Expected a line break before the next entry, but found “b”'],
		['a: 512 MiB', 'A unit cannot follow a number after a space. Write a duration without the space, as in 10s, and anything else, such as a size, as a string, as in \'512 MiB\''],
		['a: 10 seconds', 'A unit cannot follow a number after a space. Write a duration without the space, as in 10s, and anything else, such as a size, as a string, as in \'10 seconds\''],
		['a: 100 ms', 'A unit cannot follow a number after a space. Write a duration without the space, as in 100ms, and anything else, such as a size, as a string, as in \'100 ms\''],
		# `m` may be meters, so the string is offered too.
		['a: 10 m', 'A unit cannot follow a number after a space. Write a duration without the space, as in 10m, and anything else, such as a size, as a string, as in \'10 m\''],
		['a: 1.5 h # note', 'A unit cannot follow a number after a space. Write a duration without the space, as in 1.5h, and anything else, such as a size, as a string, as in \'1.5 h\''],
		['a: [100 ms]', 'A unit cannot follow a number after a space. Write a duration without the space, as in 100ms, and anything else, such as a size, as a string, as in \'100 ms\''],
		['a: {b: 100 ms}', 'A unit cannot follow a number after a space. Write a duration without the space, as in 100ms, and anything else, such as a size, as a string, as in \'100 ms\''],
		['a: [1 true]', 'Expected “,”, a line break, or “]” after an array item, but found “t”'],
		['a: 5 and more', 'Expected a line break before the next entry, but found “a”'],
		['a: \'x\' MiB', 'Expected a line break before the next entry, but found “M”'],
		["// note\na: 1", 'Expected a key, but found “/”. A comment starts with “#”'],
		['a: 1 // note', 'Expected a line break before the next entry, but found “/”. A comment starts with “#”'],
		["a: [1 // note\n]", 'Expected “,”, a line break, or “]” after an array item, but found “/”. A comment starts with “#”'],
		["a: [1, // note\n2]", 'Expected a value, but found “/”. A comment starts with “#”'],
		['a: 1 / 2', 'Expected a line break before the next entry, but found “/”'],
		["key: |\n  text", 'Expected a value, but found “|”. Write a multiline string as a block string, between \'\'\' lines'],
		# A folded block scalar joins its lines, which a block string does not.
		["key: >-\n  text", 'Expected a value, but found “>”'],
		['key: | x', 'Expected a value, but found “|”'],
		["[server]\nport: 1", 'There are no table headers. Write the table as an object, as in server: {…}'],
		["[[servers]]\nport: 1", 'There are no table headers. Write the table as an object, as in servers: {…}'],
		['a: [server]', 'Unexpected “server”. A string value must be quoted, as in \'server\''],
		["name: 'x'\n\n[server]\nport: 1", 'There are no table headers. Write the table as an object, as in server: {…}'],
		["a: 1\n[", 'Expected a key, but found “[”'],
		['{2026-09-19T14:00:00Z: 1}', 'A key that contains “:” must be quoted, as in \'2026-09-19T14:00:00Z\''],
		['12:30: \'lunch\'', 'A key that contains “:” must be quoted, as in \'12:30\''],
		['a:b: 1', 'A key that contains “:” must be quoted, as in \'a:b\''],
		['a:b', 'Unexpected “b”. A string value must be quoted, as in \'b\''],
		['a:{b: nope}', 'Unexpected “nope”. A string value must be quoted, as in \'nope\''],
		['{a: 1} x', 'Unexpected “x” after the end of the document'],
		['the name: 1', 'A bare key cannot contain spaces. Quote it, as in \'the name\''],
		["a\tb: 1", "A bare key cannot contain spaces. Quote it, as in 'a\tb'"],
		['a : 1', 'Whitespace is not allowed between a key and its “:”'],
		['a = 1', 'Expected “:” after the key, but found “=”'],
		['a.b c: 1', 'A key cannot contain “.” unless it is quoted. Quote the whole key, or use braces to nest, as in a: {b: …}'],
		['\'a\' b: 1', 'Expected “:” after the key, but found “b”'],
		['\'a\'b: 1', 'Expected “:” after the key, but found “b”'],
		["a b\n: 1", 'Expected “:” after the key, but found “b”'],
		['a/* c */: 1', 'A comment is not allowed between a key and its “:”'],
		['a/* c */  : 1', 'A comment is not allowed between a key and its “:”'],
		['{a /* c */}', 'Expected “:” after the key, but found “/”'],
		["x: 1\ny/*", 'Expected “:” after the key, but found “/”'],
		['a$: 1', 'Expected “:” after the key, but found “$”. A key that contains characters other than letters, digits, “_”, and “-” must be quoted'],
		['$schema: \'x\'', 'Expected a key, but found “$”. A key that contains characters other than letters, digits, “_”, and “-” must be quoted, as in \'$schema\''],
		['a.$b: 1', 'A key cannot contain “.” unless it is quoted. Quote the whole key, or use braces to nest, as in a: {b: …}'],
		['@a b: 1', 'Expected a key, but found “@”. A key that contains characters other than letters, digits, “_”, and “-” must be quoted'],
		["\u3164a: 1", 'Expected a key, but found U+3164'],
		["a\uFE0F: 1", 'Expected “:” after the key, but found U+FE0F'],
		["a: 1\n}", 'Expected a key, but found “}”'],
		["a:\nb: 1", 'Expected a value, but found the key b'],
		["a:\n\t12:30", 'A time of day is a string, so it must be quoted'],
		['a: 07:32:00', 'A time of day is a string, so it must be quoted'],
		['a: 12:00', 'A time of day is a string, so it must be quoted'],
		['a: 10:30 PM', 'A time of day is a string, so it must be quoted'],
		['a: 8080:80', 'Invalid number “8080:80”. A value that contains “:” must be quoted, as in \'8080:80\''],
		["color: #FFF\nsize: 1", 'Expected a value, but found the key size. “#” starts a comment, so a value that starts with “#” must be quoted, as in \'#FFF\''],
		["{color: #FFF\nsize: 1}", 'Expected a value, but found the key size. “#” starts a comment, so a value that starts with “#” must be quoted, as in \'#FFF\''],
		['color: #FFF', 'Expected a value, but reached the end of the document. “#” starts a comment, so a value that starts with “#” must be quoted, as in \'#FFF\''],
		["color: #FFF\n", 'Expected a value, but reached the end of the document. “#” starts a comment, so a value that starts with “#” must be quoted, as in \'#FFF\''],
		["{color: #FFF\n}", 'Expected a value, but found “}”. “#” starts a comment, so a value that starts with “#” must be quoted, as in \'#FFF\''],
		['color: #FFF, size: 1', 'Expected a value, but reached the end of the document. “#” starts a comment, so a value that starts with “#” must be quoted, as in \'#FFF\''],
		["color: # The color\nsize: 1", 'Expected a value, but found the key size'],
		["server:\n  port: 80", 'Expected a value, but found the key port. Indentation does not nest objects, so write server: {port: …}'],
		["ports:\n  - 80\n  - 443", 'Expected a value, but found a “-” list. An array is written in brackets, as in [80, 443]'],
		["ports:\n- 80", 'Expected a value, but found a “-” list. An array is written in brackets, as in [80, 443]'],
		["{\n\ta:\n\tb: 1\n}", 'Expected a value, but found the key b'],
		["a: 1\na: 2", 'Duplicate key a'],
		['a: hello', 'Unexpected “hello”. A string value must be quoted, as in \'hello\''],
		['a: yes', '“yes” is not a value. Booleans are written true and false, in lowercase'],
		['a: True', '“True” is not a value. Booleans are written true and false, in lowercase'],
		['a: NULL', '“NULL” is not a value. Null is written null, in lowercase'],
		['a: nan', 'NaN is not representable. Use null for a missing value'],
		['a: inf', '“inf” is not a value. Infinity is written infinity, in lowercase'],
		['a: -inf', '“-inf” is not a value. Negative infinity is written -infinity'],
		['a: +1', 'A “+” sign is not allowed. A number without a sign is positive'],
		['a: 1e+5', 'A “+” sign is not allowed in a number, including in an exponent'],
		['a: .5', 'A number cannot begin with “.”; write a digit before it, as in 0.5'],
		['a: 5.', 'A decimal point must be followed by a digit'],
		['a: 01', 'Leading zeros are not allowed in a decimal number. Write an octal number, such as a file mode, as 0o1, and an identifier, such as a ZIP code, as a string: \'01\''],
		['mode: 0644', 'Leading zeros are not allowed in a decimal number. Write an octal number, such as a file mode, as 0o644, and an identifier, such as a ZIP code, as a string: \'0644\''],
		['zip: 08901', 'Leading zeros are not allowed in a decimal number. Write an identifier, such as a ZIP code, as a string: \'08901\''],
		# The digit that is not octal comes after the length that is diagnosed, so the whole number decides that there is no octal suggestion.
		["a: 0#{'0' * 1100}8", "Leading zeros are not allowed in a decimal number. Write an identifier, such as a ZIP code, as a string: '#{'0' * 40}…'"],
		["a: 0#{'0' * 1100}7", "Leading zeros are not allowed in a decimal number. Write an identifier, such as a ZIP code, as a string: '#{'0' * 40}…'"],
		['a: 01.5', 'Leading zeros are not allowed in a decimal number'],
		['a: 1e05', 'Leading zeros are not allowed in an exponent'],
		['a: 1e-0', '“e-0” is not allowed, because an exponent of zero has one spelling: e0'],
		['a: -0', '“-0” is not allowed, because zero has one spelling: 0'],
		['a: 1__0', 'An underscore in a number must be between two digits'],
		['a: 1E5', 'An exponent marker is a lowercase “e”'],
		['a: 0xff', 'Hexadecimal digits are uppercase: 0xFF'],
		['a: 0XFF', 'A number prefix is lowercase: 0x, 0o, or 0b'],
		['a: -0xFF', 'A hexadecimal integer cannot have a sign, because it states a bit pattern rather than a quantity'],
		['a: 0o9', 'Invalid octal digit “9”'],
		['a: 0b2', 'Invalid binary digit “2”'],
		['a: 0xfg', 'Invalid hexadecimal digit “g”'],
		['a: 0x', 'Expected hexadecimal digits after “0x”'],
		['a: 1.2.3', 'Invalid number “1.2.3”. A value with several dots, such as a version number, must be quoted'],
		['a: 10sec', 'Invalid duration 10sec: “sec” is not a unit. The units are h, m, s, ms, us, and ns, and a string must be quoted'],
		['a: 2days', 'Invalid duration 2days: there is no day unit, because a day is not a fixed length. Write 24h for a fixed 24 hours'],
		['a: 12abc', 'Invalid number “12abc”. A string value must be quoted, as in \'12abc\''],
		['a: 1d', 'Invalid duration 1d: there is no day unit, because a day is not a fixed length. Write 24h for a fixed 24 hours'],
		['a: 1D', 'Invalid duration 1D: “D” is not a unit. The units are h, m, s, ms, us, and ns, and a string must be quoted'],
		['a: 1day', 'Invalid duration 1day: there is no day unit, because a day is not a fixed length. Write 24h for a fixed 24 hours'],
		['a: 1w', 'Invalid duration 1w: there is no week unit, because a day is not a fixed length. Write 168h for a fixed 168 hours'],
		['a: 1week', 'Invalid duration 1week: there is no week unit, because a day is not a fixed length. Write 168h for a fixed 168 hours'],
		['a: 2W', 'Invalid duration 2W: “W” is not a unit. The units are h, m, s, ms, us, and ns, and a string must be quoted'],
		['a: 1H', 'Invalid duration 1H: the units are lowercase: h'],
		['a: 1MS', 'Invalid duration 1MS: the units are lowercase: ms'],
		['a: 1.5h30m', 'Invalid duration 1.5h30m: only the last part may have a fraction'],
		['a: 0.5ns', 'Invalid duration 0.5ns: it is not a whole number of nanoseconds'],
		['a: 1.s', 'Invalid duration 1.s: a “.” must be followed by a digit'],
		['a: 2562048h30x', 'Invalid duration 2562048h30x: “x” is not a unit. The units are h, m, s, ms, us, and ns, and a string must be quoted'],
		['a: 1.5s-', 'Invalid duration 1.5s-: expected a number at “-”'],
		['a: 1h.5m', 'Invalid duration 1h.5m: expected a number at “.5m”'],
		# A unit and a rest are cut at 10 characters.
		['a: 1secondsxyzabc', 'Invalid duration 1secondsxyzabc: “secondsxyz…” is not a unit. The units are h, m, s, ms, us, and ns, and a string must be quoted'],
		['a: 1h.5mmmmmmmmmmmmmmmm', 'Invalid duration 1h.5mmmmmmmmmmmmmmmm: expected a number at “.5mmmmmmmm…”'],
		['a: 1.5d', 'Invalid duration 1.5d: there is no day unit, because a day is not a fixed length. Write 24h for a fixed 24 hours'],
		['a: 2weeks', 'Invalid duration 2weeks: there is no week unit, because a day is not a fixed length. Write 168h for a fixed 168 hours'],
		['a: 0_5s', 'Invalid duration 0_5s: leading zeros are not allowed'],
		['a: 1.5_s', 'Invalid duration 1.5_s: an underscore must be between two digits'],
		['a: 30m1h', 'Invalid duration 30m1h: the units are in the order h, m, s, ms, us, ns, and each appears at most once'],
		['a: 1h05m', 'Invalid duration 1h05m: leading zeros are not allowed'],
		['a: 1_s', 'Invalid duration 1_s: an underscore must be between two digits'],
		['a: 1h-30m', 'Invalid duration 1h-30m: only the whole duration takes a sign, as in -1h30m'],
		['a: 1h+30m', 'Invalid duration 1h+30m: a “+” sign is not allowed'],
		['a: 1h30', 'Invalid duration 1h30: every number needs a unit: h, m, s, ms, us, or ns'],
		['a: -0s', 'Invalid duration -0s: “-” is not allowed before zero, because zero has one spelling: 0s'],
		['a: 2562048h', 'Invalid duration 2562048h: it is outside the 64-bit range of nanoseconds, about 292 years either way'],
		['a: 1.5x', 'Invalid number “1.5x”. A string value must be quoted, as in \'1.5x\''],
		['a: 1e3s', 'Invalid number “1e3s”. A string value must be quoted, as in \'1e3s\''],
		['a: 9223372036854775808', 'The integer 9223372036854775808 is outside the 64-bit range (-9223372036854775808 to 9223372036854775807)'],
		['a: 1e999', '1e999 is too large to be a finite float. Use infinity if you mean it'],
		['a: 1e-400', '1e-400 is too small to be told apart from zero. Write 0.0 if you mean zero'],
		['a: -1e-400', '-1e-400 is too small to be told apart from zero. Write 0.0 if you mean zero'],
		['a: 2026-09-19', '2026-09-19 is a date, not an instant. Write a date as a string, as in \'2026-09-19\'. An instant needs a time and an offset, as in 2026-09-19T00:00:00Z'],
		['a: 1979-05-27 07:32:00Z', 'The date and time separator in an instant is an uppercase “T”, not a space, as in 1979-05-27T07:32:00Z'],
		['a: 1979-05-27 07:32:00.5+02:00', 'The date and time separator in an instant is an uppercase “T”, not a space, as in 1979-05-27T07:32:00.5+02:00'],
		['a: [1979-05-27 07:32:00Z]', 'The date and time separator in an instant is an uppercase “T”, not a space, as in 1979-05-27T07:32:00Z'],
		['a: 1979-05-27 07:32:00', 'The date and time separator in an instant is an uppercase “T”, not a space, and an instant needs the offset it was meant in, as in 1979-05-27T07:32:00Z for UTC. A date and time without an offset is a local time, which is not an instant, so write it as a string, as in \'1979-05-27 07:32:00\''],
		['a: 1979-05-27 07:32:00,5Z', 'The date and time separator in an instant is an uppercase “T”, not a space. An instant is written as 2026-09-19T14:00:00Z, with an optional fraction of up to nine digits and an offset of Z or ±HH:MM'],
		['a: 1979-05-27 07:32', 'The date and time separator in an instant is an uppercase “T”, not a space. An instant is written as 2026-09-19T14:00:00Z, with an optional fraction of up to nine digits and an offset of Z or ±HH:MM'],
		['a: 1979-05-27 # note', '1979-05-27 is a date, not an instant. Write a date as a string, as in \'1979-05-27\'. An instant needs a time and an offset, as in 1979-05-27T00:00:00Z'],
		['retention: 6M', 'Invalid duration 6M: there is no month unit, because a month is not a fixed length. A size, such as 512M, is a string: \'6M\''],
		['memory: 512M', 'Invalid duration 512M: there is no month unit, because a month is not a fixed length. A size, such as 512M, is a string: \'512M\''],
		['a: 1h6M', 'Invalid duration 1h6M: there is no month unit, because a month is not a fixed length'],
		['a: 2026-09-19t14:00:00Z', 'The date and time separator in an instant is an uppercase “T”'],
		['a: 2026-09-19T14:00:00z', 'The UTC offset in an instant is an uppercase “Z”'],
		['a: 2026-09-19T14:00:00', 'An instant needs an offset: Z or ±HH:MM. A date and time without an offset is a local time, which is not an instant, so write it as a string, as in \'2026-09-19T14:00:00\', or add the offset it was meant in'],
		['a: 2026-09-19T14:00:00.5', 'An instant needs an offset: Z or ±HH:MM. A date and time without an offset is a local time, which is not an instant, so write it as a string, as in \'2026-09-19T14:00:00.5\', or add the offset it was meant in'],
		['a: 2026-09-19T14:00:00+0700', 'An instant\'s offset is written with a colon, as in +07:00'],
		['a: 2026-02-30T00:00:00Z', 'Invalid instant 2026-02-30T00:00:00Z: the day must be 01 to 28 in that month'],
		['a: 2026-12-31T23:59:60Z', 'Invalid instant 2026-12-31T23:59:60Z: the second must be 00 to 59, and a leap second is not representable'],
		['a: \'x', 'Unterminated string. A \'...\' string must end on the line it starts on; use a block string (\'\'\') for multiple lines'],
		['a: "x', 'Unterminated string. A "..." string must end on the line it starts on; use a block string (""") for multiple lines'],
		['a: "\q"', 'Unknown escape “\q”. The escapes are \\\\, \", \n, \t, and \u{…}; use a \'...\' string for literal backslashes'],
		['a: "\r"', 'There is no \r escape, because a carriage return cannot be represented'],
		['a: "\\\'"', 'A \' needs no escape inside "..."'],
		['a: "\u0041"', 'The four-digit \u0041 form is not an escape. Write \u{41}'],
		['a: "\u{0041}"', 'A Unicode escape may not have leading zeros; write \u{41}'],
		['a: "\u{E9}"', 'A Unicode escape uses lowercase hexadecimal digits'],
		['a: "\u{d800}"', '\u{d800} is a surrogate, which is not a Unicode scalar value'],
		['a: "\u{110000}"', '\u{110000} is above U+10FFFF, the largest Unicode scalar value'],
		['a: "\u{d}"', 'A carriage return (U+000D) cannot be represented, so \u{d} is not allowed'],
		["a: '''x\n'''", 'A block string\'s opening delimiter must be followed directly by a line break, and its content starts on the next line'],
		["a: '''\nx", 'Unterminated block string'],
		["a: '''\nWelcome!'''", 'Unterminated block string. Its closing delimiter must start a line, so move the \'\'\' at the end of line 2 to a new line'],
		["a: \"\"\"\n\tHello\n\tWelcome!\"\"\"  \nb: 1", 'Unterminated block string. Its closing delimiter must start a line, so move the """ at the end of line 3 to a new line'],
		['a: [1,000]', 'Leading zeros are not allowed in a decimal number. A comma separates items, so 1,000 is not one number. Write it as 1_000 or 1000'],
		['a: [-1,000]', 'Leading zeros are not allowed in a decimal number. A comma separates items, so -1,000 is not one number. Write it as -1_000 or -1000'],
		['a: [12,345,000]', 'Leading zeros are not allowed in a decimal number. A comma separates items, so 12,345,000 is not one number. Write it as 12_345_000 or 12345000'],
		['a: [1,234,567,000]', 'Leading zeros are not allowed in a decimal number. A comma separates items, so 1,234,567,000 is not one number. Write it as 1_234_567_000 or 1234567000'],
		['a: [12,050,000]', 'Leading zeros are not allowed in a decimal number. A comma separates items, so 12,050,000 is not one number. Write it as 12_050_000 or 12050000'],
		['a: [0x1,000]', 'Leading zeros are not allowed in a decimal number. Write an octal number, such as a file mode, as 0o0, and an identifier, such as a ZIP code, as a string: \'000\''],
		['a: [1, 000]', 'Leading zeros are not allowed in a decimal number. Write an octal number, such as a file mode, as 0o0, and an identifier, such as a ZIP code, as a string: \'000\''],
		['a: 1.5µs', 'The unit for microseconds is written us, as in 1.5us'],
		['a: 3μs', 'The unit for microseconds is written us, as in 3us'],
		['a: \'it\'\'s\'', 'There is no \'\' escape in a \'...\' string. Write a string that contains \' as "...", as in "it\'s"'],
		["a: '''\n\tx\n\t\t'''", 'This line does not start with the indentation of its block string\'s closing delimiter. Every line except a blank one must start with exactly the same spaces and tabs'],
		["'''\nk\n''': 1", 'A block string cannot be a key'],
		["a: 1\n/* x", 'Unterminated block comment'],
		["/* a /* b */\na: 1", 'Block comments cannot be nested, and their body may not contain “/*”'],
		['/* x /**/ a: 1', 'Block comments cannot be nested, and their body may not contain “/*”'],
		['a: [1 2]', 'Expected “,”, a line break, or “]” after an array item, but found “2”'],
		['a: {b: 1 c: 2}', 'Expected “,”, a line break, or “}” after an object member, but found “c”'],
		# A line break inside a block comment does not separate items.
		["a: [1 /*\n*/ 2]", 'Expected “,”, a line break, or “]” after an array item, but found “2”. A line break inside a block comment does not separate items'],
		['a: [,1]', 'Expected a value, but found “,”'],
		['a: [1,,2]', 'Expected a value, but found “,”'],
		['a: [,]', 'Expected a value, but found “,”'],
		["a: [1\n,\n,2]", 'A comma must be on the same line as the item before it. The line break already separates the items, so remove the comma'],
		["a: {b: 1\n, c: 2}", 'A comma must be on the same line as the item before it. The line break already separates the items, so remove the comma'],
		['a: {,}', 'Expected a key, but found “,”'],
		# A value left out after a `:` is still an error, because the next line is a key.
		["a: {b:\nc: 2}", 'Expected a value, but found the key c'],
		['a: [1', 'Unterminated array: expected “]”'],
		['a: {b: 1', 'Unterminated object: expected “}”'],
		["a:\u00A01", 'Expected a value, but found U+00A0 (NO-BREAK SPACE; only space, tab, and line feed are whitespace)'],
		["a: 1\u2028", 'Unexpected U+2028 (LINE SEPARATOR; only space, tab, and line feed are whitespace) after a value'],
		["a: 1\r\n", 'A carriage return (U+000D) is not allowed anywhere. Use LF line endings'],
		["\uFEFFa: 1", 'A byte order mark (BOM) is not allowed'],
		["a: \u0001", 'A raw control character (U+0001) is not allowed anywhere, including in strings and comments. In a string, write it as the escape \u{1} inside "..."'],
		['a: `x`', 'Expected a value, but found “`”'],
		["a: \u202Ex", 'Expected a value, but found U+202E (RIGHT-TO-LEFT OVERRIDE)'],
		["a: \uE000", 'Expected a value, but found U+E000'],
		["a: \uFFF9", 'Expected a value, but found U+FFF9'],
		['a: 😀', 'Expected a value, but found “😀”'],
		['a.b: 1', 'A bare key cannot contain “.”. Quote it, as in \'a.b\', or use braces to nest, as in a: {b: …}'],
		['example.com: 1', 'A bare key cannot contain “.”. Quote it, as in \'example.com\', or use braces to nest, as in example: {com: …}'],
		['a.b.c: 1', 'A bare key cannot contain “.”. Quote it, as in \'a.b.c\', or use braces to nest, as in a: {b: {c: …}}'],
		# A number is a valid bare key, so `3.14` as a key is a key with a dot, not a float.
		['3.14: \'x\'', 'A bare key cannot contain “.”. Quote it, as in \'3.14\', or use braces to nest, as in 3: {14: …}'],
		['1.5s: 1', 'A bare key cannot contain “.”. Quote it, as in \'1.5s\', or use braces to nest, as in 1: {5s: …}'],
		['{a.b: 1}', 'A bare key cannot contain “.”. Quote it, as in \'a.b\', or use braces to nest, as in a: {b: …}'],
		['[{a.b: 1}]', 'A bare key cannot contain “.”. Quote it, as in \'a.b\', or use braces to nest, as in a: {b: …}'],
		# The suggestions are only given when both are valid: a bare key with a word on both sides of every dot, and a `:` right after it.
		['\'a\'.b: 1', 'A key cannot contain “.” unless it is quoted. Quote the whole key, or use braces to nest, as in a: {b: …}'],
		['a.\'b\': 1', 'A key cannot contain “.” unless it is quoted. Quote the whole key, or use braces to nest, as in a: {b: …}'],
		['a.: 1', 'A key cannot contain “.” unless it is quoted. Quote the whole key, or use braces to nest, as in a: {b: …}'],
		['a..b: 1', 'A key cannot contain “.” unless it is quoted. Quote the whole key, or use braces to nest, as in a: {b: …}'],
		['a.b', 'A key cannot contain “.” unless it is quoted. Quote the whole key, or use braces to nest, as in a: {b: …}'],
		['.a: 1', 'Expected a key, but found “.”. A key that contains characters other than letters, digits, “_”, and “-” must be quoted, as in \'.a\''],
		['.env: 1', 'Expected a key, but found “.”. A key that contains characters other than letters, digits, “_”, and “-” must be quoted, as in \'.env\''],
		['files: {.eslintrc.json: 1}', 'Expected a key, but found “.”. A key that contains characters other than letters, digits, “_”, and “-” must be quoted, as in \'.eslintrc.json\''],
		["a: 1\n,b: 2", 'Top-level entries are separated by line breaks, not commas. Use braces for a one-line object'],
		# A value left out before a quoted key on the next line reads that key as the value.
		["a:\n'b': 1", 'Expected a value, but found the key b'],
		["a:\n\"b c\": 1", 'Expected a value, but found the key "b c"'],
		# A key with a dot is not a key, so it is reported as a value.
		["a:\nb.c: 1", "Unexpected “b”. A string value must be quoted, as in 'b.c: 1'"],
		["{a:\n'b': 1}", 'Expected a value, but found the key b'],
		["a: # c\n'b': 1", 'Expected a value, but found the key b'],
		["a:\n'b' 1", 'Expected a line break before the next entry, but found “1”'],
		# A digit or another character after the `:` of a bare key is more likely part of a value, such as an instant, whose own error is more precise.
		["a:\n2026-01-01T00:00:00Z2", 'Invalid instant “2026-01-01T00:00:00Z2”. An instant is written as 2026-09-19T14:00:00Z, with an optional fraction of up to nine digits and an offset of Z or ±HH:MM'],
		["a:\ntrue:/* c */1", 'Unexpected “:” after a value'],
		['a.', 'A key cannot contain “.” unless it is quoted. Quote the whole key, or use braces to nest, as in a: {b: …}'],
		["a.\nb: 1", 'A key cannot contain “.” unless it is quoted. Quote the whole key, or use braces to nest, as in a: {b: …}'],
		# A quoted key is written as `JSON.stringify` writes it, as in the JS reference.
		["\"q\\\"\\\\\": 1\n\"q\\\"\\\\\": 2", 'Duplicate key "q\"\\\\"'],
		["\"a\\u{1}b\": 1\n\"a\\u{1}b\": 2", 'Duplicate key "a\u0001b"'],
		["\"\\u{8}\\u{c}\\n\\t\": 1\n\"\\u{8}\\u{c}\\n\\t\": 2", 'Duplicate key "\b\f\n\t"']
	].freeze

	REASONS.each do |source, reason|
		define_method("test_the_reason_for #{source.inspect}") do
			assert_equal reason, parse_error(source).reason
		end
	end

	def test_the_reasons_are_the_same_for_a_binary_source
		REASONS.each do |source, reason|
			assert_equal reason, parse_error(source.b).reason, source.inspect
		end
	end

	# The size hint is only for a token of at most 1000 characters, as in JS.
	def test_the_size_hint_for_a_long_number
		month = 'there is no month unit, because a month is not a fixed length'
		digits = '1' * 999
		abbreviated = "#{digits[0, 40]}…"
		assert_equal "Invalid duration #{abbreviated}: #{month}. A size, such as 512M, is a string: '#{abbreviated}'", parse_error("a: #{digits}M").reason
		assert_equal "Invalid duration #{abbreviated}: #{month}", parse_error("a: #{digits}1M").reason
		assert_equal "Invalid duration #{abbreviated}: #{month}", parse_error("a: #{digits}h6M").reason
	end

	# The key quoting hint gives an example only when the key and its colon fit in 1000 UTF-16 code units, as in JS.
	def test_the_key_quoting_hint_for_a_long_key
		hint = '. A key that contains characters other than letters, digits, “_”, and “-” must be quoted'
		assert_equal "Expected a key, but found “$”#{hint}, as in '$#{'a' * 39}…'", parse_error("$#{'a' * 998}: 1").reason
		assert_equal "Expected a key, but found “$”#{hint}", parse_error("$#{'a' * 999}: 1").reason
		assert_equal "Expected a key, but found “$”#{hint}", parse_error("$#{'😀' * 500}: 1").reason
	end

	# Counting the characters outside the BMP once built a table of a million entries for every error.
	def test_an_error_is_fast
		start = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
		100.times { parse_error('a: 5x') }
		assert_operator Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - start, :<, 0.5
	end

	def test_the_key_with_spaces_hint_only_quotes_bare_words
		assert_equal "A bare key cannot contain spaces. Quote it, as in 'a-Z_09 b-_'", parse_error('a-Z_09 b-_: 1').reason

		["a b é: 1", "a b\u00A0: 1", 'a b. c: 1'].each do |source|
			assert_equal 'Expected “:” after the key, but found “b”', parse_error(source).reason
		end
	end

	# Only spaces and tabs are trimmed from the key before its colon, because other Unicode whitespace is not whitespace in SOML, and quoting the key without it would drop a character the author wrote.
	def test_a_key_with_spaces_and_unicode_whitespace_before_its_colon
		["\u3000", "\u2028", "\u2029", "\uFEFF", "\u00A0", "\u2000", "\u205F"].each do |whitespace|
			error = parse_error("a b#{whitespace}: 1")
			assert_equal ['Expected “:” after the key, but found “b”', 1, 3], [error.reason, error.line, error.column], whitespace.inspect
		end

		assert_equal "A bare key cannot contain spaces. Quote it, as in 'a b'", parse_error("a b \t: 1").reason
	end

	def test_a_long_key_read_as_a_missing_value_is_shortened
		assert_equal "Expected a value, but found the key #{'k' * 40}…", parse_error("a:\n#{'k' * 239}: 1").reason
	end

	def test_the_leading_zeros_hint_abbreviates_a_long_number
		# An octal number that long is outside the 64-bit range, so it is not suggested.
		assert_equal "Leading zeros are not allowed in a decimal number. Write an identifier, such as a ZIP code, as a string: '0#{'7' * 39}…'", parse_error("a: 0#{'7' * 60}").reason
		assert_equal "Leading zeros are not allowed in a decimal number. Write an identifier, such as a ZIP code, as a string: '0#{'9' * 39}…'", parse_error("a: 0#{'9' * 60}").reason
	end

	def test_a_frozen_error_still_has_its_messages
		error = parse_error('a').freeze
		assert_includes error.detailed_message, '> 1 | a'
		assert_equal parse_error('a').code_frame, error.code_frame
	end

	def test_a_huge_exponent
		assert_equal '1e11111111111111111111111111111111111111… is too large to be a finite float. Use infinity if you mean it', parse_error("a: 1e#{'1' * 100_000}").reason
		assert_equal '1e-1111111111111111111111111111111111111… is too small to be told apart from zero. Write 0.0 if you mean zero', parse_error("a: 1e-#{'1' * 100_000}").reason
		assert_same_value({'a' => 0.0}, SOML.parse("a: 0.0e#{'1' * 100_000}"))
	end

	# Boundaries that mutation testing found untested. The expected values are from the JS reference.
	def test_the_boundaries_of_messages
		{
			'a: 1.5E5' => 'An exponent marker is a lowercase “e”',
			'a: 1.5e-0' => '“e-0” is not allowed, because an exponent of zero has one spelling: e0',
			'a: 2026-09-10t14:00:00Z' => 'The date and time separator in an instant is an uppercase “T”',
			'a: 2026-09-19T14:00:00.000' => 'An instant needs an offset: Z or ±HH:MM. A date and time without an offset is a local time, which is not an instant, so write it as a string, as in \'2026-09-19T14:00:00.000\', or add the offset it was meant in',
			'a: 2026-09-19T14:10:00' => 'An instant needs an offset: Z or ±HH:MM. A date and time without an offset is a local time, which is not an instant, so write it as a string, as in \'2026-09-19T14:10:00\', or add the offset it was meant in',
			# More of the instant follows, so it may have an offset.
			'a: 2026-09-19T14:10:00[Europe/Oslo]' => 'An instant needs an offset: Z or ±HH:MM'
		}.each do |source, reason|
			assert_equal reason, parse_error(source).reason, source
		end
	end

	# An offset after a space is the offset the instant was meant in, so the instant is not a local time, and quoting it as a string would change its type.
	OFFSET_AFTER_SPACE = 'An instant\'s offset follows its time directly, without a space'

	def test_an_offset_after_a_space
		{
			'a: 2026-09-19T14:00:00 Z' => "#{OFFSET_AFTER_SPACE}, as in 2026-09-19T14:00:00Z",
			'a: 2026-09-19T14:00:00 +02:00' => "#{OFFSET_AFTER_SPACE}, as in 2026-09-19T14:00:00+02:00",
			'a: 2026-09-19T14:00:00.5 -07:30' => "#{OFFSET_AFTER_SPACE}, as in 2026-09-19T14:00:00.5-07:30",
			"a: 2026-09-19T14:00:00\t\tZ # note" => "#{OFFSET_AFTER_SPACE}, as in 2026-09-19T14:00:00Z",
			'a: [2026-09-19T14:00:00 Z, 1]' => "#{OFFSET_AFTER_SPACE}, as in 2026-09-19T14:00:00Z",
			'a: {b: 2026-09-19T14:00:00 Z}' => "#{OFFSET_AFTER_SPACE}, as in 2026-09-19T14:00:00Z",
			"a: [\n\t2026-09-19T14:00:00 Z\n]" => "#{OFFSET_AFTER_SPACE}, as in 2026-09-19T14:00:00Z",
			# The instant is only shown when it is valid.
			'a: 2026-02-30T14:00:00 Z' => OFFSET_AFTER_SPACE,
			'a: 0001-01-01T00:00:00 +00:01' => OFFSET_AFTER_SPACE,
			'a: 2026-09-19T14:00:00 +24:00' => OFFSET_AFTER_SPACE,
			'a: 2026-09-19T14:00:00 +02:00 # é' => "#{OFFSET_AFTER_SPACE}, as in 2026-09-19T14:00:00+02:00"
		}.each do |source, reason|
			error = parse_error(source)
			assert_equal reason, error.reason, source
			assert_equal 4, error.column, source unless source.include?("\n") || source.start_with?('a: [', 'a: {')

			# The instant that the reason shows is valid, and it is the source without the space.
			instant = reason[/(?<=as in )\S+\z/]
			next unless instant

			assert_includes source.sub(/[ \t]+(?=[Z+-])/, ''), instant
			SOML.parse("a: #{instant}")
		end
	end

	# Only an offset on its own is one, so the other errors stand.
	def test_what_is_not_an_offset_after_a_space
		{
			'a: 2026-09-19T14:00:00' => 'An instant needs an offset: Z or ±HH:MM. A date and time without an offset is a local time, which is not an instant, so write it as a string, as in \'2026-09-19T14:00:00\', or add the offset it was meant in',
			'a: 2026-09-19T14:00:00 # Z' => 'An instant needs an offset: Z or ±HH:MM. A date and time without an offset is a local time, which is not an instant, so write it as a string, as in \'2026-09-19T14:00:00\', or add the offset it was meant in',
			'a: 2026-09-19T14:00:00 Zulu' => 'An instant needs an offset: Z or ±HH:MM. A date and time without an offset is a local time, which is not an instant, so write it as a string, as in \'2026-09-19T14:00:00\', or add the offset it was meant in',
			'a: 2026-09-19T14:00:00 +02:00:00' => 'An instant needs an offset: Z or ±HH:MM. A date and time without an offset is a local time, which is not an instant, so write it as a string, as in \'2026-09-19T14:00:00\', or add the offset it was meant in',
			'a: 2026-09-19T14:00:00 +0200' => 'An instant needs an offset: Z or ±HH:MM. A date and time without an offset is a local time, which is not an instant, so write it as a string, as in \'2026-09-19T14:00:00\', or add the offset it was meant in',
			"a: 2026-09-19T14:00:00\nZ: 1" => 'An instant needs an offset: Z or ±HH:MM. A date and time without an offset is a local time, which is not an instant, so write it as a string, as in \'2026-09-19T14:00:00\', or add the offset it was meant in',
			'a: 2026-09-19T14:00 Z' => 'Invalid instant “2026-09-19T14:00”. An instant is written as 2026-09-19T14:00:00Z, with an optional fraction of up to nine digits and an offset of Z or ±HH:MM',
			'a: 2026-09-19T14:00:00Z Z' => 'Expected a line break before the next entry, but found “Z”',
			# The search for an offset reads a few bytes after the space, which can end inside a character.
			'a: 2026-09-19T14:00:00 Montréal' => 'An instant needs an offset: Z or ±HH:MM. A date and time without an offset is a local time, which is not an instant, so write it as a string, as in \'2026-09-19T14:00:00\', or add the offset it was meant in',
			'a: 2026-09-19T14:00:00 é' => 'An instant needs an offset: Z or ±HH:MM. A date and time without an offset is a local time, which is not an instant, so write it as a string, as in \'2026-09-19T14:00:00\', or add the offset it was meant in',
			'a: [2026-09-19 😀😀]' => '2026-09-19 is a date, not an instant. Write a date as a string, as in \'2026-09-19\'. An instant needs a time and an offset, as in 2026-09-19T00:00:00Z',
			'a: 2026-09-19 Montréal' => '2026-09-19 is a date, not an instant. Write a date as a string, as in \'2026-09-19\'. An instant needs a time and an offset, as in 2026-09-19T00:00:00Z',
			'a: 2026-09-19T14:00 x日本' => 'Invalid instant “2026-09-19T14:00”. An instant is written as 2026-09-19T14:00:00Z, with an optional fraction of up to nine digits and an offset of Z or ±HH:MM',
			'a: 2026-09-19T14:00:00 Zé' => 'An instant needs an offset: Z or ±HH:MM. A date and time without an offset is a local time, which is not an instant, so write it as a string, as in \'2026-09-19T14:00:00\', or add the offset it was meant in',
			'a: 2026-09-19T14:00:00 +02:0é' => 'An instant needs an offset: Z or ±HH:MM. A date and time without an offset is a local time, which is not an instant, so write it as a string, as in \'2026-09-19T14:00:00\', or add the offset it was meant in',
			'a: 1979-05-27 07:32:00 Z' => 'The date and time separator in an instant is an uppercase “T”, not a space, and an instant needs the offset it was meant in, as in 1979-05-27T07:32:00Z for UTC. A date and time without an offset is a local time, which is not an instant, so write it as a string, as in \'1979-05-27 07:32:00\''
		}.each do |source, reason|
			assert_equal reason, parse_error(source).reason, source
		end
	end

	# An instant with a part of one digit, as in the conformance cases instant/single-digit-month and instant/single-digit-hour, keeps the error that the conformance suite gives it, and so do the tokens that are almost one.
	def test_the_errors_for_tokens_that_are_almost_instants
		{
			'a: 2026-9-19' => 'Invalid number “2026-9-19”',
			'a: 2026-9-19T14:00:00' => 'Invalid number “2026-9-19T14:00:00”. A string value must be quoted, as in \'2026-9-19T14:00:00\'',
			'a: 2026-123-19T14:00:00Z' => 'Invalid number “2026-123-19T14:00:00Z”. A string value must be quoted, as in \'2026-123-19T14:00:00Z\'',
			'a: 202-09-19T14:00:00Z' => 'Invalid number “202-09-19T14:00:00Z”. A string value must be quoted, as in \'202-09-19T14:00:00Z\'',
			'a: 2026-9-19t14:00:00Z' => 'Invalid number “2026-9-19t14:00:00Z”. A string value must be quoted, as in \'2026-9-19t14:00:00Z\'',
			'a: 2026-09-19T14:00Z' => 'Invalid instant “2026-09-19T14:00Z”. An instant is written as 2026-09-19T14:00:00Z, with an optional fraction of up to nine digits and an offset of Z or ±HH:MM',
			'a: 2026-09-19T14:00:00+0200' => 'An instant\'s offset is written with a colon, as in +07:00'
		}.each do |source, reason|
			assert_equal reason, parse_error(source).reason, source
		end

		# A long token is not matched, and it keeps its own error.
		assert_match(/\AInvalid number/, parse_error("a: 2026-9-19T14:00:00.#{'1' * 1000}Z").reason)
	end

	# A duration in years is reported as one, as one in days or weeks is, rather than as a string to quote, which would change its type.
	NO_YEAR_UNIT = 'there is no year unit, because a year is not a fixed length. Write 8760h for a fixed 365 days'

	def test_a_duration_in_years
		['1y', '2years', '1year', '3yr', '3yrs', '1Y', '1YEAR', '1.5y', '1_000y', '-1y', '1y6m', '1h1y', '1y1y'].each do |duration|
			assert_equal "Invalid duration #{duration}: #{NO_YEAR_UNIT}", parse_error("a: #{duration}").reason, duration
			assert_equal "Invalid duration #{duration}: #{NO_YEAR_UNIT}", parse_error("a: [#{duration}, 1]").reason, duration
		end

		assert_equal "Invalid duration 1y: #{NO_YEAR_UNIT}", assert_raises(SOML::ParseError) { SOML::Duration.parse('1y') }.reason
		SOML.parse('a: 8760h')
	end

	# A word that only starts with a year unit is not one.
	def test_what_is_not_a_duration_in_years
		{
			'a: 100yen' => 'Invalid number “100yen”. A string value must be quoted, as in \'100yen\'',
			'a: 1yard' => 'Invalid number “1yard”. A string value must be quoted, as in \'1yard\'',
			'a: 5yo' => 'Invalid number “5yo”. A string value must be quoted, as in \'5yo\'',
			'a: 1yrsx' => 'Invalid number “1yrsx”. A string value must be quoted, as in \'1yrsx\'',
			'a: 1yearsx' => 'Invalid number “1yearsx”. A string value must be quoted, as in \'1yearsx\'',
			'a: 1y.5' => 'Invalid number “1y.5”. A string value must be quoted, as in \'1y.5\'',
			'a: 1 y' => 'A unit cannot follow a number after a space. Write a duration without the space, as in 10s, and anything else, such as a size, as a string, as in \'1 y\''
		}.each do |source, reason|
			assert_equal reason, parse_error(source).reason, source
		end
	end

	# A word that only ends with an “e”, such as a command-line flag, has no exponent.
	def test_a_word_that_ends_with_e_has_no_exponent_marker
		{
			'a: 7zip-bin-name' => 'Invalid number “7zip-bin-name”. A string value must be quoted, as in \'7zip-bin-name\'',
			'a: 1byte' => 'Invalid number “1byte”. A string value must be quoted, as in \'1byte\'',
			'a: 3-phase' => 'Invalid number “3-phase”. A string value must be quoted, as in \'3-phase\'',
			'a: 1-time' => 'Invalid number “1-time”. A string value must be quoted, as in \'1-time\'',
			'a: [100-pre, 1]' => 'Invalid number “100-pre”. A string value must be quoted, as in \'100-pre\'',
			'a: 2e-e' => 'Invalid number “2e-e”. A string value must be quoted, as in \'2e-e\'',
			'a: -verbose' => 'Expected a digit or “infinity” after “-”',
			'args: [-recursive]' => 'Expected a digit or “infinity” after “-”'
		}.each do |source, reason|
			assert_equal reason, parse_error(source).reason, source
		end
	end

	def test_a_number_that_ends_with_its_exponent_marker
		['1e', '1e-', '-1e', '1.5e', '1.5e-', '-1_0.5_0e', '0e', '0.0e-'].each do |number|
			assert_equal 'Expected digits after the exponent marker “e”', parse_error("a: #{number}").reason, number
		end
	end

	# A word after “-” that only starts like “nan” or “inf” is not meant as NaN or infinity, as for the word without the “-”.
	def test_a_word_after_a_minus_that_only_starts_like_nan_or_infinity
		{
			'a: -nano' => 'Expected a digit or “infinity” after “-”',
			'a: -nanny' => 'Expected a digit or “infinity” after “-”',
			'a: -info' => 'Expected a digit or “infinity” after “-”',
			'a: -INFO' => 'Expected a digit or “infinity” after “-”',
			'args: [-inform, PEM]' => 'Expected a digit or “infinity” after “-”',
			'a: -infinite' => 'Expected a digit or “infinity” after “-”',
			'a: -infinityx' => 'Expected a digit or “infinity” after “-”'
		}.each do |source, reason|
			assert_equal reason, parse_error(source).reason, source
		end

		# Without the “-”, the words get the same error as any word.
		assert_equal 'Unexpected “nano”. A string value must be quoted, as in \'nano\'', parse_error('a: nano').reason
		assert_equal 'Unexpected “info”. A string value must be quoted, as in \'info\'', parse_error('a: info').reason
	end

	def test_nan_and_negative_infinity_after_a_minus
		%w[-nan -NaN -NAN].each do |word|
			assert_equal 'NaN is not representable. Use null for a missing value', parse_error("a: #{word}").reason, word
		end

		%w[-inf -Inf -INF -Infinity -INFINITY].each do |word|
			assert_equal "“#{word}” is not a value. Negative infinity is written -infinity", parse_error("a: #{word}").reason, word
			assert_equal "“#{word}” is not a value. Negative infinity is written -infinity", parse_error("a: [#{word}, 1]").reason, word
		end
	end

	# A “/” without a “*” after it does not start a comment, so the text goes on, as in `km/h`, and a suggestion that ends at it would leave the rest out.
	def test_a_slash_that_does_not_start_a_comment_is_part_of_the_text
		{
			'speed: 100 km/h' => 'Expected a line break before the next entry, but found “k”',
			'a: 5 m/s' => 'Expected a line break before the next entry, but found “m”',
			'a: [5 m/s]' => 'Expected “,”, a line break, or “]” after an array item, but found “m”',
			'a: 2026-09-19T14:00:00/2026-09-20T15:00:00' => 'An instant needs an offset: Z or ±HH:MM',
			'a: [2026-09-19T14:00:00/P1D]' => 'An instant needs an offset: Z or ±HH:MM',
			'a: 2026-09-19T14:00:00 Z/x' => 'An instant needs an offset: Z or ±HH:MM. A date and time without an offset is a local time, which is not an instant, so write it as a string, as in \'2026-09-19T14:00:00\', or add the offset it was meant in'
		}.each do |source, reason|
			assert_equal reason, parse_error(source).reason, source
		end
	end

	# A block comment does end the value, so the suggestions stand.
	def test_a_block_comment_after_a_value_ends_it
		{
			'a: 5 m /* c */' => 'A unit cannot follow a number after a space. Write a duration without the space, as in 5m, and anything else, such as a size, as a string, as in \'5 m\'',
			'a: 5 m/* c */' => 'A unit cannot follow a number after a space. Write a duration without the space, as in 5m, and anything else, such as a size, as a string, as in \'5 m\'',
			'a: 2026-09-19T14:00:00/* c */' => 'An instant needs an offset: Z or ±HH:MM. A date and time without an offset is a local time, which is not an instant, so write it as a string, as in \'2026-09-19T14:00:00\', or add the offset it was meant in',
			'a: 2026-09-19T14:00:00 Z/* c */' => 'An instant\'s offset follows its time directly, without a space, as in 2026-09-19T14:00:00Z',
			'a: 2026-09-19T14:00:00 Z /* c */' => 'An instant\'s offset follows its time directly, without a space, as in 2026-09-19T14:00:00Z',
			# A `//` is a comment from another language, which the error for what follows the value names.
			'timeout: 5 s // seconds' => 'A unit cannot follow a number after a space. Write a duration without the space, as in 5s, and anything else, such as a size, as a string, as in \'5 s\'',
			'a: 5 m//c' => 'A unit cannot follow a number after a space. Write a duration without the space, as in 5m, and anything else, such as a size, as a string, as in \'5 m\'',
			'a: 2026-09-19T14:00:00 Z//c' => 'An instant\'s offset follows its time directly, without a space, as in 2026-09-19T14:00:00Z'
		}.each do |source, reason|
			assert_equal reason, parse_error(source).reason, source
		end
	end

	# An underscore next to a letter is part of a word, such as `4k_video`, not a number with a misplaced separator.
	def test_a_word_with_an_underscore_is_not_a_number
		{
			'a: 4k_video' => 'Invalid number “4k_video”. A string value must be quoted, as in \'4k_video\'',
			'a: 2x_speed' => 'Invalid number “2x_speed”. A string value must be quoted, as in \'2x_speed\'',
			'a: [5k_run, 2]' => 'Invalid number “5k_run”. A string value must be quoted, as in \'5k_run\''
		}.each do |source, reason|
			assert_equal reason, parse_error(source).reason, source
		end
	end

	# In a number, an underscore that is not between two digits is still reported as one.
	def test_a_misplaced_underscore_in_a_number
		['1_', '1__0', '1_.5', '1._5', '1_e5', '1e_5', '1e5_', '1.5_', '-1_', '1_000_', '1e-_5'].each do |number|
			assert_equal 'An underscore in a number must be between two digits', parse_error("a: #{number}").reason, number
		end
	end

	# An uppercase “E” after a number, as in `5EUR` or `10EB`, is not an exponent marker unless an exponent follows it, so lowercasing it would not make a number.
	def test_an_uppercase_e_that_does_not_start_an_exponent
		{
			'price: 5EUR' => 'Invalid number “5EUR”. A string value must be quoted, as in \'5EUR\'',
			'disk: 10EB' => 'Invalid number “10EB”. A string value must be quoted, as in \'10EB\'',
			'a: 1.5Ex' => 'Invalid number “1.5Ex”. A string value must be quoted, as in \'1.5Ex\'',
			'a: [3ED, 1]' => 'Invalid number “3ED”. A string value must be quoted, as in \'3ED\''
		}.each do |source, reason|
			assert_equal reason, parse_error(source).reason, source
		end
	end

	def test_an_uppercase_exponent_marker
		['1E5', '1E10', '1.5E-3', '-2E7', '1_0E1_0', '1E', '2E-', '1.5E'].each do |number|
			assert_equal 'An exponent marker is a lowercase “e”', parse_error("a: #{number}").reason, number
		end
	end

	# A value with a “:” that starts with a zero, such as a MAC address, is not a number with a leading zero, so removing the zero would not make it valid.
	def test_a_value_with_a_colon_that_starts_with_a_zero
		{
			'mac: 00:1A:2B:3C:4D:5E' => 'Invalid number “00:1A:2B:3C:4D:5E”. A string value must be quoted, as in \'00:1A:2B:3C:4D:5E\'',
			'mac: 01:23:45:67:89:AB' => 'Invalid number “01:23:45:67:89:AB”. A string value must be quoted, as in \'01:23:45:67:89:AB\'',
			'a: 0123:abcd::1' => 'Invalid number “0123:abcd::1”. A string value must be quoted, as in \'0123:abcd::1\'',
			'a: [00:1A:2B, 1]' => 'Invalid number “00:1A:2B”. A string value must be quoted, as in \'00:1A:2B\'',
			'a: -01:30' => 'Invalid number “-01:30”'
		}.each do |source, reason|
			assert_equal reason, parse_error(source).reason, source
		end
	end

	# Without a “:”, or with digits alone around it, the errors stand.
	def test_the_errors_for_leading_zeros_and_values_with_a_colon
		{
			'a: 01' => 'Leading zeros are not allowed in a decimal number. Write an octal number, such as a file mode, as 0o1, and an identifier, such as a ZIP code, as a string: \'01\'',
			'a: 01A' => 'Leading zeros are not allowed in a decimal number',
			'a: 00.5' => 'Leading zeros are not allowed in a decimal number',
			'a: 00:11:22:33:44:55' => 'Invalid number “00:11:22:33:44:55”. A value that contains “:” must be quoted, as in \'00:11:22:33:44:55\'',
			'a: 08:30' => 'A time of day is a string, so it must be quoted',
			'a: 1:' => 'Invalid number “1:”',
			'a: 2001:db8::1' => 'Invalid number “2001:db8::1”. A string value must be quoted, as in \'2001:db8::1\''
		}.each do |source, reason|
			assert_equal reason, parse_error(source).reason, source
		end
	end

	def test_a_three_byte_sequence_with_a_constrained_second_byte_cut_short_at_the_end
		assert_equal ['Incomplete UTF-8 sequence at the end of the input', 1, 5], parse_error("a: '\xE0\xA0".b).then { [it.reason, it.line, it.column] }
	end

	def test_a_lone_lead_byte_with_a_constrained_second_byte_at_the_end
		["\xE0", "\xED", "\xF0", "\xF4"].each do |lead|
			assert_equal 'Incomplete UTF-8 sequence at the end of the input', parse_error("a: '#{lead}".b).reason, lead.inspect
		end
	end

	def test_a_key_of_exactly_40_characters_is_not_cut_short
		assert_equal "Duplicate key #{'k' * 40}", parse_error("\"#{'k' * 40}\": 1\n\"#{'k' * 40}\": 2").reason
		assert_equal "Duplicate key #{'k' * 40}…", parse_error("\"#{'k' * 41}\": 1\n\"#{'k' * 41}\": 2").reason
	end

	def test_a_line_of_exactly_100_characters_is_not_clipped
		line = "a: [#{'1,' * 46} x ]"
		assert_equal 100, line.length
		refute_includes parse_error(line).code_frame, '…'
		assert_includes parse_error("#{line} ").code_frame, '…'
	end

	# A suggested escape is valid

	# The escape that a reason tells the user to write, if any.
	def suggested_escape(reason)
		reason[/(?<=[Ww]rite )\\u\{[0-9a-f]+\}/]
	end

	def test_a_json_surrogate_pair_is_one_escape_for_the_character_it_encodes
		{
			%w[D83D DE00] => '1f600',
			%w[d83d de00] => '1f600',
			%w[D800 DC00] => '10000',
			%w[DBFF DFFF] => '10ffff'
		}.each do |(high, low), code_point|
			escape = "\\u#{high}\\u#{low}"
			assert_equal "The four-digit #{escape} form is not an escape. Write \\u{#{code_point}}", parse_error(%(a: "#{escape}")).reason
		end
	end

	def test_a_lone_json_surrogate_has_no_escape_to_suggest
		reason = 'is not an escape, and a lone surrogate is not a Unicode scalar value. Write the character it is half of as one \u{…} escape'
		assert_equal "The four-digit \\uD83D form #{reason}", parse_error('a: "\uD83D"').reason
		assert_equal "The four-digit \\uDE00 form #{reason}", parse_error('a: "\uDE00"').reason

		# A low surrogate first, or a high surrogate before something that is not a low one, is not a pair.
		assert_equal "The four-digit \\uDE00 form #{reason}", parse_error('a: "\uDE00\uD83D"').reason
		assert_equal "The four-digit \\uD83D form #{reason}", parse_error('a: "\uD83D\uD83D"').reason
		assert_equal "The four-digit \\uD83D form #{reason}", parse_error('a: "\uD83D\u0041"').reason
		assert_equal "The four-digit \\uD83D form #{reason}", parse_error('a: "\uD83D\u{de00}"').reason
		assert_equal "The four-digit \\uD83D form #{reason}", parse_error('a: "\uD83Dx"').reason
	end

	def test_a_json_carriage_return_has_no_escape_to_suggest
		assert_equal 'The four-digit \u000D form is not an escape, and a carriage return (U+000D) cannot be represented', parse_error('a: "\u000D"').reason
		assert_equal 'The four-digit \u000d form is not an escape, and a carriage return (U+000D) cannot be represented', parse_error('a: "\u000d"').reason
	end

	def test_a_braced_escape_with_leading_zeros_is_reported_for_its_value_first
		assert_equal 'A carriage return (U+000D) cannot be represented, so \u{000d} is not allowed', parse_error('a: "\u{000d}"').reason
		assert_equal '\u{00d800} is a surrogate, which is not a Unicode scalar value', parse_error('a: "\u{00d800}"').reason
		assert_equal '\u{0dfff} is a surrogate, which is not a Unicode scalar value', parse_error('a: "\u{0dfff}"').reason
		assert_equal 'A Unicode escape may not have leading zeros; write \u{11000}', parse_error('a: "\u{011000}"').reason
		assert_equal 'A Unicode escape may not have leading zeros; write \u{0}', parse_error('a: "\u{00}"').reason
	end

	# Lowercasing the digits of these escapes would give an escape that is not allowed either.
	def test_a_braced_escape_with_uppercase_digits_is_reported_for_its_value_first
		assert_equal 'A carriage return (U+000D) cannot be represented, so \u{D} is not allowed', parse_error('a: "\u{D}"').reason
		assert_equal 'A carriage return (U+000D) cannot be represented, so \u{00D} is not allowed', parse_error('a: "\u{00D}"').reason
		assert_equal '\u{D800} is a surrogate, which is not a Unicode scalar value', parse_error('a: "\u{D800}"').reason
		assert_equal '\u{dFfF} is a surrogate, which is not a Unicode scalar value', parse_error('a: "\u{dFfF}"').reason
		assert_equal '\u{FFFFFF} is above U+10FFFF, the largest Unicode scalar value', parse_error('a: "\u{FFFFFF}"').reason
		assert_equal '\u{11000F} is above U+10FFFF, the largest Unicode scalar value', parse_error('a: "\u{11000F}"').reason
		assert_equal 'A carriage return (U+000D) cannot be represented, so \u{D} is not allowed', parse_error(%(a: """\n\t\\u{D}\n\t""")).reason
		assert_equal 'A carriage return (U+000D) cannot be represented, so \u{D} is not allowed', parse_error('"\u{D}": 1').reason
	end

	# The uppercase error is only for an escape whose value is allowed, so lowercasing its digits never gives an escape whose value is not allowed, and it comes before the leading zeros error, as before.
	def test_a_braced_escape_with_uppercase_digits_and_an_allowed_value
		assert_equal 'A Unicode escape uses lowercase hexadecimal digits', parse_error('a: "\u{E9}"').reason
		assert_equal 'A Unicode escape uses lowercase hexadecimal digits', parse_error('a: "\u{1F600}"').reason
		assert_equal 'A Unicode escape uses lowercase hexadecimal digits', parse_error('a: "\u{10FFFF}"').reason
		assert_equal 'A Unicode escape uses lowercase hexadecimal digits', parse_error('a: "\u{00E9}"').reason
		assert_equal 'A Unicode escape uses lowercase hexadecimal digits', parse_error('a: "\u{D7FF}"').reason
		assert_equal 'A Unicode escape uses lowercase hexadecimal digits', parse_error('a: "\u{E000}"').reason
		assert_equal 'A Unicode escape uses lowercase hexadecimal digits', parse_error('a: "\u{C}"').reason

		# Seven digits is not an escape in any case.
		assert_equal 'A Unicode escape uses lowercase hexadecimal digits', parse_error('a: "\u{FFFFFFF}"').reason
		assert_equal 'A Unicode escape has at most six hexadecimal digits', parse_error('a: "\u{1234567}"').reason
	end

	def test_the_suggestions_in_a_block_string_are_the_same
		assert_equal "The four-digit \\uD83D\\uDE00 form is not an escape. Write \\u{1f600}", parse_error(%(a: """\n\t\\uD83D\\uDE00\n\t""")).reason
		assert_equal 'A carriage return (U+000D) cannot be represented, so \u{0d} is not allowed', parse_error(%(a: """\n\t\\u{0d}\n\t""")).reason
	end

	def test_every_four_digit_form_suggests_an_escape_that_reads_as_the_character_json_reads
		(0..0xFFFF).each do |code|
			escape = format('\\u%04X', code)
			suggestion = suggested_escape(parse_error(%(a: "#{escape}")).reason)
			is_representable = code != 0x0D && !code.between?(0xD800, 0xDFFF)
			assert_equal is_representable, !suggestion.nil?, escape
			next if suggestion.nil?

			assert_equal JSON.parse(%("#{escape}")), SOML.parse(%(a: "#{suggestion}"))['a'], escape
		end
	end

	def test_every_surrogate_pair_suggests_an_escape_that_reads_as_the_character_json_reads
		0xD800.step(0xDBFF, 0x31) do |high|
			0xDC00.step(0xDFFF, 0x29) do |low|
				escape = "\\u#{high.to_s(16)}\\u#{low.to_s(16)}"
				suggestion = suggested_escape(parse_error(%(a: "#{escape}")).reason)
				refute_nil suggestion, escape
				assert_equal JSON.parse(%("#{escape}")), SOML.parse(%(a: "#{suggestion}"))['a'], escape
			end
		end
	end

	def test_every_braced_form_with_leading_zeros_suggests_a_valid_escape_or_none
		%w[00 000 0041 00e9 000d 0d800 00dbff 0dc00 0dfff 0e000 01f600 000010].each do |hex|
			reason = parse_error(%(a: "\\u{#{hex}}")).reason
			suggestion = suggested_escape(reason)
			next if suggestion.nil?

			assert_equal "\\u{#{hex.sub(/\A0+(?=.)/, '')}}", suggestion, reason
			SOML.parse(%(a: "#{suggestion}"))
		end
	end

	# A suggested quoted string holds the whole unquoted value

	[
		['name: John Smith', 'John Smith'],
		['name: John Smith # The owner', 'John Smith'],
		["name: John Smith \t\nisAdmin: true", 'John Smith'],
		['a: foo.bar', 'foo.bar'],
		['a: foo/bar', 'foo/bar'],
		['a: v1.2.3', 'v1.2.3'],
		['a: C# and F#', 'C# and F#'],
		['a: say "hi"', 'say "hi"'],
		['a: [foo bar, true]', 'foo bar'],
		['a: [foo bar]', 'foo bar'],
		['a: {b: foo bar}', 'foo bar'],
		['a: {b: foo bar, c: true}', 'foo bar'],
		["a: [\n\tfoo bar\n]", 'foo bar'],
		['a: héllo wörld 😀', 'héllo wörld 😀']
	].each do |source, text|
		define_method("test_the_quoting_suggestion_for #{source.inspect}") do
			reason = parse_error(source).reason
			assert reason.end_with?("A string value must be quoted, as in '#{text}'"), reason

			# The suggestion is what was meant: with the text quoted, the document is valid and holds it.
			assert_includes SOML.parse(source.sub(text, "'#{text}'")).to_s, text.inspect
		end
	end

	def test_the_word_itself_is_still_what_is_unexpected
		assert_equal "Unexpected “John”. A string value must be quoted, as in 'John Smith'", parse_error('name: John Smith').reason
		assert_equal "Unexpected “hello”. A string value must be quoted, as in 'hello'", parse_error('a: hello').reason
	end

	def test_a_value_that_holds_a_single_quote_has_no_literal_string_to_suggest
		assert_equal 'Unexpected “it”. A string value must be quoted', parse_error("a: it's here").reason
	end

	def test_a_long_value_is_cut_short_in_the_suggestion
		words = Array.new(1000, 'word').join(' ')
		assert_equal "Unexpected “word”. A string value must be quoted, as in '#{words[0, 40]}…'", parse_error("a: #{words}").reason
	end

	# The text is read up to 1000 UTF-16 code units, as in JS, so a `'` after them does not take the example away.
	def test_a_single_quote_after_the_first_1000_code_units_keeps_the_example
		assert_equal 'Unexpected “a”. A string value must be quoted', parse_error("x: a #{'b' * 997}'").reason
		assert_equal "Unexpected “a”. A string value must be quoted, as in 'a #{'b' * 38}…'", parse_error("x: a #{'b' * 998}'").reason
		assert_equal "Unexpected “a”. A string value must be quoted, as in 'a #{'😀' * 19}…'", parse_error("x: a #{'😀' * 499}'").reason
		assert_equal 'Unexpected “a”. A string value must be quoted', parse_error("x: a #{'😀' * 498}'").reason
		assert_equal "Unexpected “a”. A string value must be quoted, as in 'a #{'é' * 38}…'", parse_error("x: a #{'é' * 998}'").reason
		assert_equal 'Unexpected “a”. A string value must be quoted', parse_error("x: a #{'é' * 997}'").reason
	end

	[
		['border: 1px solid black', "Invalid number “1px”. A string value must be quoted, as in '1px solid black'"],
		['font: 12pt Arial # Body', "Invalid number “12pt”. A string value must be quoted, as in '12pt Arial'"],
		['a: [1px solid, 2]', "Invalid number “1px”. A string value must be quoted, as in '1px solid'"],
		['a: 1px', "Invalid number “1px”. A string value must be quoted, as in '1px'"],
		["a: 3x it's", 'Invalid number “3x”. A string value must be quoted'],
		# The octal suggestion is only for the number on its own.
		['phone: 0412 345 678', "Leading zeros are not allowed in a decimal number. Write an identifier, such as a ZIP code, as a string: '0412 345 678'"],
		['date: 01/02/2026', "Leading zeros are not allowed in a decimal number. Write an identifier, such as a ZIP code, as a string: '01/02/2026'"],
		['mode: 0644', "Leading zeros are not allowed in a decimal number. Write an octal number, such as a file mode, as 0o644, and an identifier, such as a ZIP code, as a string: '0644'"],
		['mode: 0644 # Owner', "Leading zeros are not allowed in a decimal number. Write an octal number, such as a file mode, as 0o644, and an identifier, such as a ZIP code, as a string: '0644'"],
		['a: [0644, 1]', "Leading zeros are not allowed in a decimal number. Write an octal number, such as a file mode, as 0o644, and an identifier, such as a ZIP code, as a string: '0644'"]
	].each do |source, reason|
		define_method("test_the_quoting_suggestion_for_a_value_that_starts_with_a_number #{source.inspect}") do
			assert_equal reason, parse_error(source).reason
		end
	end

	def test_a_block_comment_after_a_space_or_a_tab_ends_the_value
		assert_equal "Unexpected “hello”. A string value must be quoted, as in 'hello world'", parse_error('a: hello world /* note */').reason
		assert_equal "Unexpected “hello”. A string value must be quoted, as in 'hello world'", parse_error("a: [hello world\t/* note */]").reason
		assert_equal "Invalid number “1px”. A string value must be quoted, as in '1px solid'", parse_error('a: 1px solid /* note */').reason
	end

	def test_a_block_comment_opening_directly_after_the_text_is_part_of_it
		assert_equal "Unexpected “src”. A string value must be quoted, as in 'src/*.js'", parse_error('a: src/*.js').reason
		assert_equal "Unexpected “C”. A string value must be quoted, as in 'C#'", parse_error('a: C#').reason
	end

	def test_text_with_a_single_quote_gets_no_identifier_example
		assert_equal 'Leading zeros are not allowed in a decimal number. Write an identifier, such as a ZIP code, as a string', parse_error("a: 01234 O'Brien").reason
		assert_equal 'Leading zeros are not allowed in a decimal number. Write an identifier, such as a ZIP code, as a string', parse_error("a: 0899 x'y").reason
	end

	# A word after the `:` of a member and a space is an unquoted string, not a key

	[
		['url: https://example.com', "Unexpected “https”. A string value must be quoted, as in 'https://example.com'"],
		['url: https://example.com/a?b=c # The API', "Unexpected “https”. A string value must be quoted, as in 'https://example.com/a?b=c'"],
		['host: localhost:8080', "Unexpected “localhost”. A string value must be quoted, as in 'localhost:8080'"],
		['a: {url: https://x, b: true}', "Unexpected “https”. A string value must be quoted, as in 'https://x'"],
		['a: x:y', "Unexpected “x”. A string value must be quoted, as in 'x:y'"],
		['msg: Error: file not found', "Unexpected “Error”. A string value must be quoted, as in 'Error: file not found'"],
		['a: [Note: x, true]', 'Expected a value, but found the key Note'],
		['a: {msg: Error: x}', "Unexpected “Error”. A string value must be quoted, as in 'Error: x'"],
		['a: b:', "Unexpected “b”. A string value must be quoted, as in 'b:'"],
		["a:\tb: 1", "Unexpected “b”. A string value must be quoted, as in 'b: 1'"],
		["a: \t https://x", "Unexpected “https”. A string value must be quoted, as in 'https://x'"],
		['a: {b: c:d}', "Unexpected “c”. A string value must be quoted, as in 'c:d'"],
		# Anywhere else, a key where a value should be is reported as a key, as when the value of an entry is left out, or in an array, even when it was meant as text.
		["a:\nb: 1", 'Expected a value, but found the key b'],
		["a:\nb:\t1", 'Expected a value, but found the key b'],
		["a:\nb:", 'Expected a value, but found the key b'],
		["a:\nb:1\nc: 2", 'Expected a value, but found the key b'],
		["{a:\nb:1}", 'Expected a value, but found the key b'],
		["a: [\n\t3\n\tc: 5\n]", 'Expected a value, but found the key c'],
		['[a:1]', 'Expected a value, but found the key a'],
		['x: [a:b, c]', 'Expected a value, but found the key a'],
		['a: [https://x, true]', 'Expected a value, but found the key https'],
		['a: /* c */ b: 1', 'Expected a value, but found the key b']
	].each do |source, reason|
		define_method("test_a_word_with_a_colon_after_it #{source.inspect}") do
			assert_equal reason, parse_error(source).reason
		end
	end

	# A suggested uppercase hexadecimal integer is valid and in range

	[
		['a: 0xff', 'Hexadecimal digits are uppercase: 0xFF'],
		['a: 0xff_ff', 'Hexadecimal digits are uppercase: 0xFF_FF'],
		['a: 0xFf', 'Hexadecimal digits are uppercase: 0xFF'],
		['a: 0x00ff', 'Hexadecimal digits are uppercase: 0x00FF'],
		# The uppercase spelling would still be invalid, so the underscore is reported.
		['a: 0x_ff', 'An underscore in a number must be between two digits'],
		['a: 0xff_', 'An underscore in a number must be between two digits'],
		['a: 0xf__f', 'An underscore in a number must be between two digits'],
		['a: 0x_FF', 'An underscore in a number must be between two digits'],
		['a: 0x7fffffffffffffff', 'Hexadecimal digits are uppercase: 0x7FFFFFFFFFFFFFFF'],
		['a: 0x0000_7fff_ffff_ffff_ffff', 'Hexadecimal digits are uppercase: 0x0000_7FFF_FFFF_FFFF_FFFF'],
		# The uppercase spelling would be outside the 64-bit range, so there is no example.
		['a: 0x8000000000000000a', 'Hexadecimal digits are uppercase'],
		['a: 0xffffffffffffffff', 'Hexadecimal digits are uppercase'],
		['a: 0x8000000000000000_0000a', 'Hexadecimal digits are uppercase'],
		# The lowercase digits come after the length that is diagnosed, so the whole number decides the reason.
		["a: 0x#{'1' * 1100}ff", 'Hexadecimal digits are uppercase'],
		["a: 0x#{'1' * 1100}f_f", 'Hexadecimal digits are uppercase'],
		["a: 0x#{'1' * 1100}f__f", 'An underscore in a number must be between two digits']
	].each do |source, reason|
		define_method("test_the_hexadecimal_case_suggestion_for #{source.inspect}") do
			assert_equal reason, parse_error(source).reason
		end
	end

	# An octal or binary integer is checked as a whole too, without a regex that repeats over every digit.

	[
		['a: -0o7', 'An octal integer cannot have a sign, because it states a bit pattern rather than a quantity'],
		['a: -0b1', 'A binary integer cannot have a sign, because it states a bit pattern rather than a quantity'],
		['a: 0o', 'Expected octal digits after “0o”'],
		['a: 0b', 'Expected binary digits after “0b”'],
		['a: 0b1_', 'An underscore in a number must be between two digits'],
		['a: 0o_7', 'An underscore in a number must be between two digits'],
		['a: 0b1__1', 'An underscore in a number must be between two digits'],
		["a: 0b#{'1' * 1100}2", 'Invalid binary digit “2”'],
		["a: 0o#{'7' * 1100}_", 'An underscore in a number must be between two digits'],
		["a: 0x#{'F' * 1100}G", 'Invalid hexadecimal digit “G”']
	].each do |source, reason|
		define_method("test_the_radix_reason_for #{source[0, 20].inspect} #{source.bytesize}") do
			assert_equal reason, parse_error(source).reason
		end
	end

	def test_every_uppercase_hexadecimal_suggestion_parses_to_the_value_the_lowercase_digits_mean
		valid = %w[a f 0a a0 ab_cd a_b_c 7fffffffffffffff dead_beef]

		[*valid, *%w[_a a_ a__b a_b_ _ 8000000000000000]].each do |digits|
			reason = parse_error("a: 0x#{digits}").reason
			suggestion = reason[/(?<=uppercase: )\S+\z/]
			assert_equal valid.include?(digits), !suggestion.nil?, reason
			next if suggestion.nil?

			assert_same_value({'a' => digits.delete('_').to_i(16)}, SOML.parse("a: #{suggestion}"), reason)
		end
	end

	# A date is only shown as an instant when the date exists

	{
		'2026-09-19' => true,
		'2024-02-29' => true,
		'2000-02-29' => true,
		'0001-01-01' => true,
		'9999-12-31' => true,
		'2026-04-30' => true,
		'2026-02-30' => false,
		'2025-02-29' => false,
		'1900-02-29' => false,
		'2026-04-31' => false,
		'2026-13-01' => false,
		'2026-00-10' => false,
		'2026-01-00' => false,
		'2026-01-32' => false,
		'0000-01-01' => false
	}.each do |date, is_existing|
		define_method("test_the_date_error_for #{date}") do
			as_string = "#{date} is a date, not an instant. Write a date as a string, as in '#{date}'"
			reason = parse_error("a: #{date}").reason
			assert_equal is_existing ? "#{as_string}. An instant needs a time and an offset, as in #{date}T00:00:00Z" : as_string, reason

			# The instant that the reason shows is valid.
			instant = reason[/(?<=as in )[0-9]{4}-[0-9]{2}-[0-9]{2}T00:00:00Z\z/]
			SOML.parse("a: #{instant}") if instant
		end
	end

	# A float that is too large suggests the infinity of its sign

	[
		['1e999', 'infinity'],
		['1.7976931348623159e308', 'infinity'],
		['-1e999', '-infinity'],
		['-1.7976931348623159e308', '-infinity'],
		['-1_000e1_000', '-infinity'],
		['-1.5e400', '-infinity'],
		["-1e#{'9' * 30}", '-infinity']
	].each do |literal, infinity|
		define_method("test_the_overflow_suggestion_for #{literal[0, 40]}") do
			assert_equal "#{literal[0, 40]}#{literal.length > 40 ? '…' : ''} is too large to be a finite float. Use #{infinity} if you mean it", parse_error("a: #{literal}").reason

			# The suggestion reads as the infinity of the literal's sign.
			assert_same_value({'a' => literal.start_with?('-') ? -Float::INFINITY : Float::INFINITY}, SOML.parse("a: #{infinity}"))
		end
	end

	# A missing `:` is only explained as a key with spaces when the `:` ends the key

	[
		# Quoting the words before the `:` would give a valid document with another meaning, or still an invalid one.
		['server localhost:8080', 'Expected “:” after the key, but found “l”'],
		['time 12:30', 'Expected “:” after the key, but found “1”'],
		['homepage https://example.com', 'Expected “:” after the key, but found “h”'],
		['the name: 1', "A bare key cannot contain spaces. Quote it, as in 'the name'"],
		["the name:\t1", "A bare key cannot contain spaces. Quote it, as in 'the name'"],
		["the name:\n\t1", "A bare key cannot contain spaces. Quote it, as in 'the name'"],
		['the name:', "A bare key cannot contain spaces. Quote it, as in 'the name'"],
		["a: 1\nthe name: 2", "A bare key cannot contain spaces. Quote it, as in 'the name'"],
		# Text directly after the `:` could be the value, as in `the name:1`, or part of it, as in `server localhost:8080`, so there is no hint.
		['the name:1', 'Expected “:” after the key, but found “n”'],
		["a: {b c:'d'}", 'Expected “:” after the key, but found “c”']
	].each do |source, reason|
		define_method("test_the_missing_colon_error_for #{source.inspect}") do
			assert_equal reason, parse_error(source).reason
		end
	end

	# A value that starts with `.` is only a number when a digit follows

	[
		['a: .5', 'A number cannot begin with “.”; write a digit before it, as in 0.5'],
		['a: .5e3', 'A number cannot begin with “.”; write a digit before it, as in 0.5'],
		['a: [.5]', 'A number cannot begin with “.”; write a digit before it, as in 0.5'],
		['a: .env', "Unexpected “.”. A string value must be quoted, as in '.env'"],
		['a: ./foo # The path', "Unexpected “.”. A string value must be quoted, as in './foo'"],
		['files: [.env, .git]', "Unexpected “.”. A string value must be quoted, as in '.env'"],
		['a: ...', "Unexpected “.”. A string value must be quoted, as in '...'"],
		['a: .', "Unexpected “.”. A string value must be quoted, as in '.'"],
		["a: .it's", 'Unexpected “.”. A string value must be quoted']
	].each do |source, reason|
		define_method("test_the_error_for_a_value_that_starts_with_a_dot #{source.inspect}") do
			assert_equal reason, parse_error(source).reason
		end
	end

	# A keyword hint is only given for a word on its own

	[
		['a: Yes', '“Yes” is not a value. Booleans are written true and false, in lowercase'],
		['a: None # Unset', '“None” is not a value. Null is written null, in lowercase'],
		['a: [NaN, 1]', 'NaN is not representable. Use null for a missing value'],
		['a: Inf', '“Inf” is not a value. Infinity is written infinity, in lowercase'],
		["a: TRUE \t", '“TRUE” is not a value. Booleans are written true and false, in lowercase'],
		# Following the hint would change the value or leave text behind, so the text is a string.
		['a: Yes please', "Unexpected “Yes”. A string value must be quoted, as in 'Yes please'"],
		['status: On hold', "Unexpected “On”. A string value must be quoted, as in 'On hold'"],
		['a: None of the above', "Unexpected “None”. A string value must be quoted, as in 'None of the above'"],
		['name: Nan Goldin', "Unexpected “Nan”. A string value must be quoted, as in 'Nan Goldin'"],
		['a: [Inf loop, 1]', "Unexpected “Inf”. A string value must be quoted, as in 'Inf loop'"],
		["a: No, it's not", "“No” is not a value. Booleans are written true and false, in lowercase"],
		["a: Off's", 'Unexpected “Off”. A string value must be quoted']
	].each do |source, reason|
		define_method("test_the_keyword_hint_for #{source.inspect}") do
			assert_equal reason, parse_error(source).reason
		end
	end

	# An invalid digit after a radix prefix is the one named

	[
		['a: 0xffg', 'Invalid hexadecimal digit “g”'],
		['a: 0xFfz', 'Invalid hexadecimal digit “z”'],
		['a: 0xFG', 'Invalid hexadecimal digit “G”'],
		['a: 0xabcdefg', 'Invalid hexadecimal digit “g”'],
		['a: 0o78', 'Invalid octal digit “8”'],
		['a: 0o7a', 'Invalid octal digit “a”'],
		['a: 0b102', 'Invalid binary digit “2”']
	].each do |source, reason|
		define_method("test_the_invalid_digit_for #{source.inspect}") do
			assert_equal reason, parse_error(source).reason
		end
	end

	# A `=` after a key is not a reason to quote it

	[
		['name=foo', 'Expected “:” after the key, but found “=”'],
		['port=8080', 'Expected “:” after the key, but found “=”'],
		['{a=1}', 'Expected “:” after the key, but found “=”'],
		['a = 1', 'Expected “:” after the key, but found “=”'],
		['"a"=1', 'Expected “:” after the key, but found “=”'],
		# Other characters directly after a key are still most likely part of it.
		['a$: 1', 'Expected “:” after the key, but found “$”. A key that contains characters other than letters, digits, “_”, and “-” must be quoted'],
		# A key that holds a `=` gets the hint without the example, because the `=` was most likely meant as the `:`.
		['$a=b: 1', 'Expected a key, but found “$”. A key that contains characters other than letters, digits, “_”, and “-” must be quoted'],
		['=a: 1', 'Expected a key, but found “=”']
	].each do |source, reason|
		define_method("test_the_error_for_an_equals_sign_after_a_key #{source.inspect}") do
			assert_equal reason, parse_error(source).reason
		end
	end

	# The suggestions, with their positions. The expected values are from the JS reference.
	SUGGESTIONS = [
		["a: x\t# c", "Unexpected “x”. A string value must be quoted, as in 'x'", 1, 4],
		["a: x\t/* c */", "Unexpected “x”. A string value must be quoted, as in 'x'", 1, 4],
		['a: {b: x y}', "Unexpected “x”. A string value must be quoted, as in 'x y'", 1, 8],
		['[foo bar]', "Unexpected “foo”. A string value must be quoted, as in 'foo bar'", 1, 2],
		['a: x  ,', "Unexpected “x”. A string value must be quoted, as in 'x'", 1, 4],
		["a: [x # c\n]", "Unexpected “x”. A string value must be quoted, as in 'x'", 1, 5],
		["\n\turl: https://x", "Unexpected “https”. A string value must be quoted, as in 'https://x'", 2, 7],
		["url: \"https://x\"\nb: https://y", "Unexpected “https”. A string value must be quoted, as in 'https://y'", 2, 4],
		['a: [1, Yes]', '“Yes” is not a value. Booleans are written true and false, in lowercase', 1, 8],
		["a: Yes\t# c", '“Yes” is not a value. Booleans are written true and false, in lowercase', 1, 4],
		['a: [é, x y]', 'Expected a value, but found “é”', 1, 5],
		["a: 'é' + é y", 'Expected a line break before the next entry, but found “+”', 1, 8],
		["a: 0x#{'0' * 50}ff", "Hexadecimal digits are uppercase: 0x#{'0' * 38}…", 1, 4],
		["a: 0x#{'f' * 50}", 'Hexadecimal digits are uppercase', 1, 4],
		['a: 2400-02-29', "2400-02-29 is a date, not an instant. Write a date as a string, as in '2400-02-29'. An instant needs a time and an offset, as in 2400-02-29T00:00:00Z", 1, 4],
		['a: 2100-02-29', "2100-02-29 is a date, not an instant. Write a date as a string, as in '2100-02-29'", 1, 4],
		['the name:# c', 'Expected “:” after the key, but found “n”', 1, 5],
		['the name:/* c */ 1', 'Expected “:” after the key, but found “n”', 1, 5],
		["the name:\n", "A bare key cannot contain spaces. Quote it, as in 'the name'", 1, 1],
		['a b c: 1', "A bare key cannot contain spaces. Quote it, as in 'a b c'", 1, 1],
		["a: 1\n\n  a: .env", "Unexpected “.”. A string value must be quoted, as in '.env'", 3, 6],
		['a: "\u000Dx"', 'The four-digit \u000D form is not an escape, and a carriage return (U+000D) cannot be represented', 1, 5],
		["a: \"x\\uD83D\\uDE00\\uD83D\"", 'The four-digit \uD83D' + '\uDE00 form is not an escape. Write \u{1f600}', 1, 6],
		['a: 0xg', 'Invalid hexadecimal digit “g”', 1, 4],
		['a: -1e309', '-1e309 is too large to be a finite float. Use -infinity if you mean it', 1, 4],
		["a=1\nb: 2", 'Expected “:” after the key, but found “=”', 1, 2],
		['a.b=1', 'A key cannot contain “.” unless it is quoted. Quote the whole key, or use braces to nest, as in a: {b: …}', 1, 2]
	].freeze

	SUGGESTIONS.each do |source, reason, line, column|
		define_method("test_the_suggestion_and_its_position_for #{source.inspect[0, 60]}") do
			error = parse_error(source)
			assert_equal [reason, line, column], [error.reason, error.line, error.column]
		end
	end

	# The suggestions read the source by bytes, so they must not depend on its encoding.
	def test_the_suggestions_are_the_same_for_a_binary_or_utf16_source
		SUGGESTIONS.each do |source, reason, line, column|
			[source.b, source.encode(Encoding::UTF_16LE)].each do |encoded|
				error = parse_error(encoded)
				assert_equal [reason, line, column], [error.reason, error.line, error.column], "#{source.inspect} in #{encoded.encoding}"
			end
		end
	end

	def test_format_and_edit_give_the_same_suggestions
		error = assert_raises(SOML::ParseError) { SOML.format('url: https://example.com') }
		assert_equal "Unexpected “https”. A string value must be quoted, as in 'https://example.com'", error.reason

		error = assert_raises(SOML::ParseError) { SOML.edit("name: John Smith\n", ['name'], 'x') }
		assert_equal "Unexpected “John”. A string value must be quoted, as in 'John Smith'", error.reason
	end

	# A value that starts with "#" is only shown quoted when a literal string can hold it

	COMMENT_AS_VALUE_HINT = '“#” starts a comment, so a value that starts with “#” must be quoted'

	[
		["a: #don't", "Expected a value, but reached the end of the document. #{COMMENT_AS_VALUE_HINT}"],
		["a: #'x'", "Expected a value, but reached the end of the document. #{COMMENT_AS_VALUE_HINT}"],
		["a: #it's\nb: 1", "Expected a value, but found the key b. #{COMMENT_AS_VALUE_HINT}"],
		["{a: #it's\n}", "Expected a value, but found “}”. #{COMMENT_AS_VALUE_HINT}"],
		['a: #dont', "Expected a value, but reached the end of the document. #{COMMENT_AS_VALUE_HINT}, as in '#dont'"],
		['a: #say"hi"', "Expected a value, but reached the end of the document. #{COMMENT_AS_VALUE_HINT}, as in '#say\"hi\"'"]
	].each do |source, reason|
		define_method("test_the_comment_as_value_hint_for #{source.inspect}") do
			assert_equal reason, parse_error(source).reason
		end
	end

	def test_every_example_of_a_value_that_starts_with_a_hash_is_a_valid_string_that_holds_the_value
		['#FFF', '#a\\b', '#say"hi"', '#1.5', '#é😀'].each do |value|
			example = parse_error("a: #{value}").reason[/(?<=as in ).+\z/]
			assert_same_value({'a' => value}, SOML.parse("a: #{example}"))
		end
	end

	# The regex only sees the start of a long comment, which is cut short in the message anyway.
	def test_a_huge_comment_where_a_value_was_meant_to_start_with_a_hash
		comment = "##{'x' * 1_000_000}"
		reason = /“#” starts a comment, so a value that starts with “#” must be quoted, as in '#x+…'\z/
		assert_match reason, parse_error("a: #{comment}").reason
		parse_error("a: #{comment}\nb: 1")
		assert_match reason, parse_error("{a: #{comment}\n}").reason
		assert_match reason, assert_raises(SOML::ParseError) { SOML.format("a: #{comment}") }.reason

		# A `'` after the first 1000 UTF-16 code units does not take the example away, as in JS.
		assert_match reason, parse_error("a: #{comment[0, 1000]}'").reason
		refute_match reason, parse_error("a: #{comment[0, 999]}'").reason
		assert_match(/as in '#😀+…'\z/, parse_error("a: ##{'😀' * 499}x'").reason)
		refute_match(/as in/, parse_error("a: ##{'😀' * 499}'").reason)
	end

	# A suggested octal integer is in range

	[
		['a: 0777777777777777777777', '777777777777777777777', '0777777777777777777777'],
		['a: 0000777777777777777777777', '777777777777777777777', '0000777777777777777777777'],
		# The largest octal int is 0o777777777777777777777, so one more digit is outside the 64-bit range.
		['a: 01000000000000000000000', nil, '01000000000000000000000'],
		['a: 01777777777777777777777', nil, '01777777777777777777777'],
		['a: 07777777777777777777777777', nil, '07777777777777777777777777']
	].each do |source, digits, text|
		define_method("test_the_octal_suggestion_for #{source.inspect}") do
			octal = digits ? "an octal number, such as a file mode, as 0o#{digits}, and " : ''
			assert_equal "Leading zeros are not allowed in a decimal number. Write #{octal}an identifier, such as a ZIP code, as a string: '#{text}'", parse_error(source).reason
		end
	end

	def test_every_octal_suggestion_parses_to_the_value_the_digits_mean_in_octal
		['00', '07', '0644', '0755', '00007', '0777777777777777777777', '01000000000000000000000', '0' * 30].each do |digits|
			suggestion = parse_error("a: #{digits}").reason[/(?<=as )0o[0-9]+(?=,)/]

			if suggestion.nil?
				assert_operator digits.to_i(8), :>, 9_223_372_036_854_775_807, digits
				next
			end

			assert_same_value({'a' => digits.to_i(8)}, SOML.parse("a: #{suggestion}"))
		end
	end

	# A number with thousands separators is only suggested when it is in range

	def thousands_separator_reason(number)
		"Leading zeros are not allowed in a decimal number. A comma separates items, so #{number} is not one number"
	end

	[
		['a: [9,223,372,036,854,775,807]', '9,223,372,036,854,775,807', '. Write it as 9_223_372_036_854_775_807 or 9223372036854775807'],
		['a: [-9,223,372,036,854,775,808]', '-9,223,372,036,854,775,808', '. Write it as -9_223_372_036_854_775_808 or -9223372036854775808'],
		['a: [9,223,372,036,854,775,808]', '9,223,372,036,854,775,808', ''],
		['a: [-9,223,372,036,854,775,809]', '-9,223,372,036,854,775,809', ''],
		['a: [10,000,000,000,000,000,000]', '10,000,000,000,000,000,000', '']
	].each do |source, number, suggestion|
		define_method("test_the_thousands_separator_suggestion_for #{source.inspect}") do
			assert_equal "#{thousands_separator_reason(number)}#{suggestion}", parse_error(source).reason
		end
	end

	def test_every_thousands_separator_suggestion_parses_to_the_number_without_its_commas
		['1,000', '-1,000', '999,000', '12,345,000', '9,223,372,036,854,775,807', '9,223,372,036,854,775,808', '-9,223,372,036,854,775,809'].each do |number|
			value = number.delete(',').to_i
			suggestions = parse_error("a: [#{number}]").reason.match(/(?<=Write it as )(\S+) or (\S+)\z/)

			if suggestions.nil?
				refute value.between?(-(2**63), (2**63) - 1), number
				next
			end

			suggestions.captures.each do |suggestion|
				assert_same_value({'a' => [value]}, SOML.parse("a: [#{suggestion}]"))
			end
		end
	end

	# A date and a time with a space between them are only shown as an instant when it is valid

	SPACE_SEPARATOR = 'The date and time separator in an instant is an uppercase “T”, not a space'
	INSTANT_FORMAT_HINT = "#{SPACE_SEPARATOR}. An instant is written as 2026-09-19T14:00:00Z, with an optional fraction of up to nine digits and an offset of Z or ±HH:MM"

	[
		['a: 2024-02-29 14:00:00Z', "#{SPACE_SEPARATOR}, as in 2024-02-29T14:00:00Z"],
		['a: 2026-01-01 14:00:00.123456789Z', "#{SPACE_SEPARATOR}, as in 2026-01-01T14:00:00.123456789Z"],
		['a: 2026-02-30 14:00:00Z', INSTANT_FORMAT_HINT],
		['a: 2025-02-29 14:00:00Z', INSTANT_FORMAT_HINT],
		['a: 2026-01-01 24:00:00Z', INSTANT_FORMAT_HINT],
		['a: 2026-01-01 14:60:00Z', INSTANT_FORMAT_HINT],
		['a: 2026-01-01 14:00:60Z', INSTANT_FORMAT_HINT],
		['a: 2026-01-01 14:00:00.1234567890Z', INSTANT_FORMAT_HINT],
		['a: 2026-01-01 14:00:00-00:00', INSTANT_FORMAT_HINT],
		['a: 2026-01-01 14:00:00+24:00', INSTANT_FORMAT_HINT],
		# In UTC, these fall outside the years 0001 to 9999.
		['a: 0001-01-01 00:00:00+01:00', INSTANT_FORMAT_HINT],
		['a: 9999-12-31 23:59:59-01:00', INSTANT_FORMAT_HINT],
		# A local time is only suggested in UTC when that is valid.
		['a: 2024-02-29 14:00:00', "#{SPACE_SEPARATOR}, and an instant needs the offset it was meant in, as in 2024-02-29T14:00:00Z for UTC. A date and time without an offset is a local time, which is not an instant, so write it as a string, as in '2024-02-29 14:00:00'"],
		['a: 2026-02-30 14:00:00', INSTANT_FORMAT_HINT],
		['a: 2026-01-01 25:00:00', INSTANT_FORMAT_HINT],
		['a: 0000-01-01 00:00:00', INSTANT_FORMAT_HINT]
	].each do |source, reason|
		define_method("test_the_space_separated_instant_error_for #{source.inspect}") do
			assert_equal reason, parse_error(source).reason
			instant = reason[/(?<=as in )\S+T\S+/]
			SOML.parse("a: #{instant}") if instant
		end
	end

	# A duration without the space is only suggested when it is valid

	def unit_after_space_reason(duration, text)
		"A unit cannot follow a number after a space. Write a duration without the space, as in #{duration}, and anything else, such as a size, as a string, as in '#{text}'"
	end

	[
		['a: 1.5 us', '1.5us', '1.5 us'],
		['a: -5 m', '-5m', '-5 m'],
		['a: 1_000 ms', '1_000ms', '1_000 ms'],
		['a: 2562047 h', '2562047h', '2562047 h'],
		# Not a whole number of nanoseconds.
		['a: 1.5 ns', '10s', '1.5 ns'],
		['a: 0.0000000001 s', '10s', '0.0000000001 s'],
		# Zero has no negative spelling.
		['a: -0.0 s', '10s', '-0.0 s'],
		# Outside the 64-bit range of nanoseconds.
		['a: 2562048 h', '10s', '2562048 h'],
		['a: 3000000 h', '10s', '3000000 h'],
		# An exponent or a radix prefix cannot be part of a duration.
		['a: 1e3 ms', '10s', '1e3 ms'],
		['a: 0x10 s', '10s', '0x10 s']
	].each do |source, duration, text|
		define_method("test_the_unit_after_a_space_error_for #{source.inspect}") do
			assert_equal unit_after_space_reason(duration, text), parse_error(source).reason
		end
	end

	def test_every_suggested_duration_without_the_space_is_valid
		['1', '-1', '0', '0.5', '1.5', '-1.5', '1_000', '1e3', '0x1F', '0o7', '0b1', '-0.0', '9223372036854775807', '0.000000001', '0.0000000001'].each do |number|
			%w[h m s ms us ns].each do |unit|
				duration = parse_error("a: #{number} #{unit}").reason[/(?<=as in )\S+(?=,)/]
				SOML.parse("a: #{duration}")
			end
		end
	end

	def test_a_huge_number_followed_by_a_space_and_a_unit
		reason = /\AA unit cannot follow a number after a space/
		assert_match reason, parse_error("a: 1.#{'0' * 1_000_000} ms").reason
		assert_match reason, parse_error("a: 1.#{'0_' * 500_000}5 ms").reason
		assert_match reason, parse_error("a: [1.#{'0' * 1_000_000}5 MiB]").reason
	end

	# A duration in microseconds written with µ is only suggested with us when it is valid

	[
		['a: 1µs', 'The unit for microseconds is written us, as in 1us'],
		['a: -1_000μs', 'The unit for microseconds is written us, as in -1_000us'],
		['a: 0.001µs', 'The unit for microseconds is written us, as in 0.001us'],
		# Not a whole number of nanoseconds.
		['a: 1.0005µs', 'The unit for microseconds is written us'],
		# Zero has no negative spelling.
		['a: -0.0µs', 'The unit for microseconds is written us'],
		# An exponent or a radix prefix cannot be part of a duration.
		['a: 1e3µs', 'The unit for microseconds is written us'],
		['a: 0x10µs', 'The unit for microseconds is written us'],
		# Outside the 64-bit range of nanoseconds.
		['a: 9223372036854775µs', 'The unit for microseconds is written us, as in 9223372036854775us'],
		['a: 9223372036854776µs', 'The unit for microseconds is written us']
	].each do |source, reason|
		define_method("test_the_microseconds_error_for #{source.inspect}") do
			assert_equal reason, parse_error(source).reason
			duration = reason[/(?<=as in )\S+\z/]
			SOML.parse("a: #{duration}") if duration
		end
	end

	# A table header is only reported where a table could be written instead, and for a name that is a valid key

	def table_header_reason(name)
		"There are no table headers. Write the table as an object, as in #{name}: {…}"
	end

	[
		["[server]\nport: 1", 'server'],
		["# The server.\n[server]\nport: 1", 'server'],
		["\t[server]\nport: 1", 'server'],
		["[[servers]]\nport: 1", 'servers'],
		["a: 1\n[server]\nport: 1", 'server'],
		["a: {\n\t[server]\n}", 'server'],
		["[a-b_c]\nport: 1", 'a-b_c']
	].each do |source, name|
		define_method("test_the_table_header_error_for #{source.inspect}") do
			assert_equal table_header_reason(name), parse_error(source).reason
		end
	end

	# Only the first 1000 UTF-16 code units of the line are read, as in JS, and a character outside the BMP that ends past them stops the match, as the half of it that JS reads does.
	def test_a_table_header_is_read_as_far_as_in_js
		name = "#{'a' * 40}…"
		unquoted = "Unexpected “#{name}”. A string value must be quoted, as in '#{name}'"
		assert_equal unquoted, parse_error("[#{'a' * 996}]😀").reason
		assert_equal unquoted, parse_error("[#{'a' * 997}]😀").reason
		assert_equal table_header_reason(name), parse_error("[#{'a' * 998}]😀").reason
	end

	[
		# An item of a nested array cannot be a member, so a word in brackets there is an unquoted string.
		["roles: [\n\t[admin]\n]", "Unexpected “admin”. A string value must be quoted, as in 'admin'"],
		["a: [\n\t1,\n\t[x]\n]", "Unexpected “x”. A string value must be quoted, as in 'x'"],
		["[\n\t1,\n\t[x]\n]", "Unexpected “x”. A string value must be quoted, as in 'x'"],
		["[\n\t[[x]]\n]", "Unexpected “x”. A string value must be quoted, as in 'x'"],
		# A value left out before a word in brackets on the next line, as YAML nests a flow sequence, is not a table either.
		["a:\n[server]\nport: 1", "Unexpected “server”. A string value must be quoted, as in 'server'"],
		["a:\n  [server]", "Unexpected “server”. A string value must be quoted, as in 'server'"],
		["{a:\n[server]\n}", "Unexpected “server”. A string value must be quoted, as in 'server'"],
		# A bare key cannot contain a dot.
		["[a.b]\nport: 1", "Unexpected “a”. A string value must be quoted, as in 'a.b'"],
		["[a.]\nport: 1", "Unexpected “a”. A string value must be quoted, as in 'a.'"],
		["[[a.b]]\nport: 1", "Unexpected “a”. A string value must be quoted, as in 'a.b'"],
		["x: 1\n[a.b]\nport: 1", 'Expected a key, but found “[”']
	].each do |source, reason|
		define_method("test_a_word_in_brackets_that_is_no_table_header #{source.inspect}") do
			assert_equal reason, parse_error(source).reason
		end
	end

	def test_every_suggested_table_key_is_valid
		['a', 'a.b', 'a.b.c', 'a-b', '_a', 'a..b', 'a.', 'a.b.', 'a...b'].each do |name|
			suggestion = parse_error("[#{name}]\nport: 1").reason[/(?<=as in )\S+(?=: \{…\})/]
			next if suggestion.nil?

			assert_equal name, suggestion
			SOML.parse("#{suggestion}: {port: 1}")
		end
	end

	# The keys in the suggestion for an indented key are written as in a document

	[
		["server:\n  port: 80", 'Expected a value, but found the key port. Indentation does not nest objects, so write server: {port: …}'],
		["'a.b':\n  'c.d': 1", "Expected a value, but found the key \"c.d\". Indentation does not nest objects, so write 'a.b': {'c.d': …}"],
		["'the server':\n  'the port': 80", "Expected a value, but found the key \"the port\". Indentation does not nest objects, so write 'the server': {'the port': …}"],
		["\"it's\":\n  b: 1", "Expected a value, but found the key b. Indentation does not nest objects, so write \"it's\": {b: …}"],
		["\"a\\u{1}\":\n  b: 1", 'Expected a value, but found the key b. Indentation does not nest objects, so write "a\u{1}": {b: …}'],
		["a:\n  \"\\u{8}\\u{c}\\u{7f}\": 1", "Expected a value, but found the key \"\\b\\f\uFFFD\". Indentation does not nest objects, so write a: {\"\\u{8}\\u{c}\\u{7f}\": …}"],
		["a:\n  \"b\\\\c\": 1", "Expected a value, but found the key \"b\\\\c\". Indentation does not nest objects, so write a: {'b\\c': …}"]
	].each do |source, reason|
		define_method("test_the_indented_key_suggestion_for #{source.inspect}") do
			assert_equal reason, parse_error(source).reason
		end
	end

	def test_the_suggestion_for_an_indented_key_is_a_valid_document_with_the_value_nested_under_the_key
		[['a', 'b'], ["'a b'", '"c\u{1}"'], ['"\u{7f}"', '"\t"'], ["'x.y'", "'é😀'"]].each do |parent, child|
			match = parse_error("#{parent}:\n  #{child}: 1").reason.match(/so write (?<braced>.+): \{(?<inner>.+): …\}\z/)
			assert_same_value SOML.parse("#{parent}: {#{child}: 1}"), SOML.parse("#{match[:braced]}: {#{match[:inner]}: 1}")
		end
	end

	# Every fix that an error suggests is valid

	# The documents that each fix in a reason makes, where the fix is a value, a key, or an escape. A fix cut short with "…" is left out, because it is not the whole fix.
	def suggested_documents(reason)
		documents = []

		# Each pattern captures the fix. Onigmo has no lookbehind of variable length, so the text before a fix is matched rather than looked behind.
		[
			/as in ('[^\n']*')(?=\z|[,.] | for )/,
			# An offset, as in "written with a colon, as in +07:00", is part of an instant, not a value.
			/as in (?![+\-]\d{2}:\d{2}\z)([^\s']+)(?=, and anything else|\z)/,
			/uppercase: (0x\S+)\z/,
			/as (0o\S+)(?=, and)/,
			/Write it as (\S+)(?= or \S+\z)/,
			/Write it as \S+ or (\S+)\z/,
			/Use (-?infinity)(?= if you mean it)/
		].each do |pattern|
			reason.scan(pattern) { |(value)| documents << "a: #{value}" }
		end

		reason.scan(/as in (\S+)(?=Z for UTC)/) { |(value)| documents << "a: #{value}Z" }
		reason.scan(/(?<=[Ww]rite )\\u\{[0-9a-f]+\}/) { documents << "a: \"#{it}\"" }

		if (indentation = reason.match(/so write (?<parent>.+): \{(?<child>.+): …\}\z/))
			documents << "#{indentation[:parent]}: {#{indentation[:child]}: 1}"
		end

		if (table = reason.match(/as in (?<name>.+): \{…\}\z/))
			documents << "#{table[:name]}: {}"
		end

		if (dot = reason.match(/Quote it, as in (?<key>'.+'), or use braces to nest, as in (?<nested>.+): …(?<closing>\}*)\z/))
			documents << "#{dot[:key]}: 1" << "#{dot[:nested]}: 1#{dot[:closing]}"
		end

		documents.reject { it.include?('…') }
	end

	# Each valid conformance case with a piece inserted, or with a piece in place of one to three characters, at seeded random positions.
	def mutations
		root = File.join(__dir__, 'conformance', 'valid')
		files = Dir.glob('**/*.soml', base: root).reject { it.end_with?('.canonical.soml', '.formatted.soml') }.sort
		# Pieces that make the mistakes that the errors suggest fixes for.
		pieces = [' ', "\n", "\n  ", ',', ':', '.', '..', "'", '"', '#', '\\', '-', '_', '0', '00', '1', '9', 'a', 'e', 'x', 'T', ' T', 'Z', 'z', 's', 'm', 'h', ' h', ' ms', ' s', ' ns', 'µs', '0x', '0o', 'f', '\\u00', '\\u{0', '\\u{1}', '[', ']', '[a]', '[a..b]', ' 14:00:00', ':00', '+02:00', '-00:00', ',000', '0000']
		random = Random.new(1)

		files.flat_map do |file|
			original = File.binread(File.join(root, file)).force_encoding(Encoding::UTF_8)

			Array.new(25) do
				position = random.rand(0..original.length)
				piece = pieces.sample(random: random)
				"#{original[0, position]}#{piece}#{original[(random.rand < 0.5 ? position : position + random.rand(1..3))..]}"
			end
		end
	end

	def test_every_fix_in_the_errors_for_mutations_of_every_valid_conformance_case_is_valid
		checked = 0

		mutations.each do |mutated|
			reason = begin
				SOML.parse(mutated)
				next
			rescue SOML::ParseError => error
				error.reason
			end

			suggested_documents(reason).each do |document|
				checked += 1

				begin
					SOML.parse(document)
				rescue SOML::ParseError => error
					flunk "The error for #{mutated.inspect}, #{reason.inspect}, suggests #{document.inspect}, which is invalid: #{error.reason}"
				end
			end
		end

		# The mutations reach the suggestions, so the test checks something.
		assert_operator checked, :>, 1000
	end
end
