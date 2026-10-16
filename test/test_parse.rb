# frozen_string_literal: true

# Unit tests for `SOML.parse`, ported from soml-js's `test/parse.ts`.
#
# The JS tests that do not apply to Ruby are left out: the `integers` option, prototype hardening, running without `Temporal`, and values from another realm. A JS `Uint8Array` is a binary `String` here, and a JS lone surrogate is a surrogate encoded in UTF-8, which is invalid UTF-8 in Ruby.

require_relative 'test_helper'
require 'json'
require 'time'
require 'tmpdir'

class TestParse < Minitest::Test
	def value_of(source)
		SOML.parse(source)['a']
	end

	def instant(text)
		Time.iso8601(text).utc
	end

	def duration(nanoseconds)
		SOML::Duration.new(nanoseconds:)
	end

	# Input

	def test_accepts_a_string
		assert_same_value({'a' => 1}, SOML.parse('a: 1'))
	end

	def test_accepts_a_binary_string_of_utf8
		assert_same_value({'a' => 'é😀'}, SOML.parse("a: 'é😀'".b))
	end

	def test_accepts_a_us_ascii_string
		assert_same_value({'a' => 1}, SOML.parse('a: 1'.encode(Encoding::US_ASCII)))
	end

	def test_accepts_a_slice_of_a_larger_binary_string
		assert_same_value({'a' => 1}, SOML.parse('xxa: 1xx'.b.byteslice(2, 4)))
	end

	def test_converts_a_string_in_another_encoding_to_utf8
		assert_same_value({'a' => 'é'}, SOML.parse("a: 'é'".encode(Encoding::UTF_16LE)))
		assert_same_value({'a' => 'é'}, SOML.parse("a: '\xE9'".dup.force_encoding(Encoding::Windows_1252)))
		assert_same_value({'a' => 'é'}, SOML.parse("a: 'é'".encode(Encoding::ISO_8859_1)))
	end

	def test_accepts_an_object_that_converts_implicitly_to_a_string
		source = Object.new

		def source.to_str
			'a: 1'
		end

		assert_same_value({'a' => 1}, SOML.parse(source))
	end

	class Source < BasicObject
		def to_str = 'a: 1'
	end

	class Opaque < BasicObject; end

	# A `BasicObject` has none of the methods that the conversion or its error would call on it, except the `to_str` it defines.
	def test_a_basic_object_converts_with_to_str_or_is_named_by_its_class
		assert_same_value({'a' => 1}, SOML.parse(Source.new))
		assert_equal "a: 1\n", SOML.format(Source.new)
		assert_equal 'a: 2', SOML.edit(Source.new, ['a'], 2)
		assert_equal 'no implicit conversion of TestParse::Opaque into String', assert_raises(TypeError) { SOML.parse(Opaque.new) }.message
		assert_equal 'no implicit conversion of TestParse::Opaque into String', assert_raises(TypeError) { SOML::Duration.parse(Opaque.new) }.message
	end

	def test_an_empty_binary_string_is_an_empty_invalid_document
		assert_match(/empty/, parse_error(''.b).reason)
	end

	def test_rejects_other_input_types_with_a_type_error
		[nil, 1, true, {}, [], :x, 1.5, BasicObject.new].each do |input|
			assert_raises(TypeError) { SOML.parse(input) }
		end
	end

	def test_the_type_error_names_what_it_got
		assert_equal 'no implicit conversion of Integer into String', assert_raises(TypeError) { SOML.parse(1) }.message
		assert_equal 'no implicit conversion of nil into String', assert_raises(TypeError) { SOML.parse(nil) }.message
		assert_equal 'no implicit conversion of Hash into String', assert_raises(TypeError) { SOML.parse({}) }.message

		# As Ruby names them, as in `File.read(true)`.
		assert_equal 'no implicit conversion of true into String', assert_raises(TypeError) { SOML.parse(true) }.message
		assert_equal 'no implicit conversion of false into String', assert_raises(TypeError) { SOML.parse(false) }.message

		# A `BasicObject` has no `nil?` or `class`.
		assert_equal 'no implicit conversion of BasicObject into String', assert_raises(TypeError) { SOML.parse(BasicObject.new) }.message
	end

	def test_a_byte_order_mark_in_bytes_is_rejected_rather_than_stripped
		assert_match(/byte order mark/, parse_error("\xEF\xBB\xBFa: 1".b).reason)
	end

	def test_invalid_utf8_after_a_byte_order_mark_counts_the_mark_as_a_column
		error = parse_error("\xEF\xBB\xBFa\xFF".b)
		assert_equal ['Invalid UTF-8 byte 0xFF', 1, 3], [error.reason, error.line, error.column]
	end

	def test_invalid_utf8_at_the_very_start
		error = parse_error("\x80".b)
		assert_equal ['Invalid UTF-8 byte 0x80', 1, 1], [error.reason, error.line, error.column]
	end

	# A lone surrogate cannot be in a valid UTF-8 string, so the JS lone surrogate checks are the UTF-8 encoding of one here.
	def test_a_surrogate_encoded_in_utf8_is_invalid_utf8
		error = parse_error("a: '\xED\xA0\x80'")
		assert_equal ['Invalid UTF-8 byte 0xED', 1, 5], [error.reason, error.line, error.column]

		assert_equal 'Invalid UTF-8 byte 0xED', parse_error("a: '\xED\xB0\x80'").reason

		error = parse_error("a: 'x\xED\xA0\xBD'")
		assert_equal ['Invalid UTF-8 byte 0xED', 6], [error.reason, error.column]

		assert_equal 'Invalid UTF-8 byte 0xED', parse_error("# \xED\xA0\x80\na: 1").reason
	end

	def test_a_surrogate_pair_encoded_in_utf8_is_invalid_utf8
		assert_equal 'Invalid UTF-8 byte 0xED', parse_error("a: '\xED\xA0\xBD\xED\xB8\x80'").reason
	end

	def test_an_astral_character_is_accepted
		assert_same_value({'a' => '😀'}, SOML.parse("a: '\u{1F600}'"))
	end

	# Options

	def test_symbolize_names_makes_every_key_a_symbol
		assert_equal({a: {b: {c: 1}}, list: [{d: 2}], 'e f': 3}, SOML.parse("a: {b: {c: 1}}\nlist: [{d: 2}]\n'e f': 3", symbolize_names: true))
	end

	def test_symbolize_names_leaves_string_values_alone
		assert_same_value 'x', SOML.parse("a: 'x'", symbolize_names: true)[:a]
	end

	def test_without_freeze_the_result_is_mutable
		value = SOML.parse("a: {b: ['x']}")
		refute_predicate value, :frozen?
		refute_predicate value['a'], :frozen?
		refute_predicate value['a']['b'], :frozen?
		refute_predicate value['a']['b'][0], :frozen?
	end

	# Type mapping

	def test_objects_are_plain_hashes_with_string_keys
		value = SOML.parse('a: {b: [{c: 1}]}')
		assert_instance_of Hash, value
		assert_instance_of Hash, value['a']
		assert_instance_of Hash, value['a']['b'][0]
		assert_equal ['c'], value['a']['b'][0].keys
		assert_instance_of String, value.keys.first
	end

	def test_the_top_level_array_is_a_plain_array
		assert_instance_of Array, SOML.parse('[1]')
	end

	def test_negative_zero_becomes_zero
		assert_equal '0.0', value_of('a: -0.0').to_s
		assert_equal '0.0', value_of('a: -0e5').to_s
	end

	def test_infinity
		assert_same_value({'a' => Float::INFINITY, 'b' => -Float::INFINITY}, SOML.parse("a: infinity\nb: -infinity"))
	end

	def test_instants_keep_nanoseconds
		time = value_of('a: 2026-09-19T14:00:00.123456789Z')
		assert_equal Rational(1_789_826_400_123_456_789, 1_000_000_000), time.to_r
		assert_equal 123_456_789, time.nsec
	end

	# Each part is read from its place in the token, so every part at its smallest and largest value, and a fraction of every length, reads as `Time` reads it.
	def test_every_part_of_an_instant_at_its_limits
		{
			'0001-01-01T00:00:00Z' => Time.utc(1, 1, 1),
			'9999-12-31T23:59:59.999999999Z' => Time.utc(9999, 12, 31, 23, 59, Rational(59_999_999_999, 1_000_000_000)),
			'2024-02-29T12:34:56+23:59' => Time.new(2024, 2, 29, 12, 34, 56, '+23:59'),
			'2023-02-28T12:34:56-23:59' => Time.new(2023, 2, 28, 12, 34, 56, '-23:59'),
			'2000-02-29T00:00:00+00:00' => Time.utc(2000, 2, 29),
			'1000-10-10T10:10:10.5-10:10' => Time.new(1000, 10, 10, 10, 10, Rational(21, 2), '-10:10'),
			'0001-01-01T00:00:00-00:01' => Time.utc(1, 1, 1, 0, 1),
			'9999-12-31T23:59:59+00:01' => Time.utc(9999, 12, 31, 23, 58, 59)
		}.each do |text, expected|
			assert_equal expected.to_r, value_of("a: #{text}").to_r, text
		end

		(1..9).each do |length|
			fraction = '123456789'[0, length]
			assert_equal Rational(fraction.to_i, 10**length), value_of("a: 2026-09-19T14:00:00.#{fraction}Z").subsec, fraction
		end
	end

	def test_instants_are_normalized_to_the_same_instant_regardless_of_offset
		value = SOML.parse("a: 2026-09-19T14:00:00Z\nb: 2026-09-19T16:00:00+02:00")
		assert_equal value['a'], value['b']
		assert_predicate value['b'], :utc?
		assert_equal 14, value['b'].hour
	end

	def test_an_int_is_exact_across_the_whole_int64_range
		assert_same_value 9_223_372_036_854_775_807, value_of('a: 9223372036854775807')
		assert_same_value(-9_223_372_036_854_775_808, value_of('a: -9223372036854775808'))
		assert_same_value 9_007_199_254_740_993, value_of('a: 9007199254740993')
	end

	# Documents

	def test_a_brace_less_object
		assert_same_value({'name' => 'x', 'version' => '1.0.0'}, SOML.parse("name: 'x'\nversion: '1.0.0'"))
	end

	def test_a_braced_object_is_the_same_value
		assert_same_value SOML.parse("name: 'x'\nversion: '1.0.0'"), SOML.parse("{name: 'x', version: '1.0.0'}")
	end

	def test_an_array
		assert_same_value [1, 'two', true, nil], SOML.parse("[1, 'two', true, null]")
	end

	def test_a_line_break_separates_items_as_a_comma_does
		assert_same_value [80, 443], SOML.parse("[\n80\n443\n]")
		assert_same_value({'a' => 1, 'b' => 2}, SOML.parse("{\na: 1\nb: 2\n}"))
		assert_same_value({'ports' => [80, 443]}, SOML.parse("ports: [\n\t80\n\t443\n]"))
	end

	def test_commas_and_line_breaks_may_be_mixed
		assert_same_value [1, 2, 3], SOML.parse("[1, 2\n3]")
		assert_same_value [1, 2], SOML.parse("[1,\n\n2]")
		assert_same_value({'a' => 1, 'b' => 2, 'c' => 3}, SOML.parse("{a: 1, b: 2\nc: 3}"))
	end

	def test_a_trailing_comma_is_still_allowed
		assert_same_value [1], SOML.parse('[1,]')
		assert_same_value [1], SOML.parse("[1,\n]")
		assert_same_value [1], SOML.parse("[1, # x\n]")
	end

	def test_a_comma_must_be_on_the_line_of_the_item_before_it
		assert_same_value [1, 2], SOML.parse("[1, # c\n2]")
		assert_same_value [1, 2], SOML.parse("[1 /* a\n */, 2]")

		["[1\n, 2]", "[1\n,\n2]", "[1\n,]", "[\n\t1\n\t,\n]", "{a: 1\n, b: 2}", "[1 # c\n, 2]"].each do |source|
			assert_raises(SOML::ParseError, source.inspect) { SOML.parse(source) }
		end
	end

	def test_a_line_break_separates_only_outside_a_comment
		assert_same_value [1, 2], SOML.parse("[1 # x\n2]")
		assert_same_value [1, 2], SOML.parse("[1 /* x */\n2]")
		assert_same_value [1, 2], SOML.parse("[1\n/* x */ 2]")
	end

	def test_a_line_break_after_a_colon_is_whitespace
		assert_same_value({'a' => 1}, SOML.parse("{a:\n1}"))
		assert_same_value({'a' => 1, 'b' => 2}, SOML.parse("{a:\n1\nb:\n2}"))
	end

	def test_the_form_is_decided_by_the_first_character_after_comments
		assert_same_value [1], SOML.parse("# x\n/* y */ [1]")
		assert_same_value({'a' => 1}, SOML.parse("# x\n/* y */ {a: 1}"))
	end

	def test_the_order_of_members_does_not_change_the_value
		assert_equal SOML.parse('{a: 1, b: 2}'), SOML.parse('{b: 2, a: 1}')
	end

	def test_members_keep_their_document_order
		assert_equal %w[b a c], SOML.parse("b: 1\na: 2\nc: 3").keys

		value = SOML.parse('{b: 1, a: {d: 1, c: 2}}')
		assert_equal %w[b a], value.keys
		assert_equal %w[d c], value['a'].keys
	end

	# Keys

	def test_a_quoted_key_with_a_dot_is_one_key
		assert_same_value({'a.b' => 1, 'example.com' => 2, '3.14' => 3}, SOML.parse("'a.b': 1\n\"example.com\": 2\n'3.14': 3"))
		assert_same_value({'a.b' => {'a.b' => 1}}, SOML.parse("{'a.b': {'a.b': 1}}"))
	end

	def test_a_quoted_key_may_hold_a_line_feed_written_as_an_escape
		assert_same_value({"a\nb" => 1}, SOML.parse('"a\nb": 1'))
		assert_same_value({"\n" => 1}, SOML.parse('{"\n": 1}'))
	end

	def test_a_quoted_key_is_shown_quoted_in_errors
		assert_equal 'Duplicate key "a b"', parse_error("'a b': 1\n'a b': 2").reason
	end

	# Duplicate keys

	def test_duplicate_keys_are_decided_on_the_decoded_key
		['a', "'a'", '"a"', '"\u{61}"'].each do |second|
			error = parse_error("a: 1\n#{second}: 2")
			assert_equal ['Duplicate key a', 2, 1], [error.reason, error.line, error.column], second
		end
	end

	def test_duplicate_keys_do_not_normalize_unicode
		assert_equal ["\u00E9", "e\u0301"], SOML.parse("\"\\u{e9}\": 1\n\"e\\u{301}\": 2").keys
	end

	def test_duplicate_keys_are_case_sensitive
		assert_same_value({'a' => 1, 'A' => 2}, SOML.parse("a: 1\nA: 2"))
	end

	# Keys that are special elsewhere. JS guards its prototype; in Ruby they are only strings, and must stay plain members.

	def test_keys_that_are_special_in_other_languages_are_plain_members
		value = SOML.parse("__proto__: {polluted: true}\nconstructor: {prototype: {polluted: true}}\ndefault: 1\nto_s: 2\nclass: 3")
		assert_same_value({'__proto__' => {'polluted' => true}, 'constructor' => {'prototype' => {'polluted' => true}}, 'default' => 1, 'to_s' => 2, 'class' => 3}, value)
		assert_nil value.default
	end

	def test_special_key_duplicates_are_detected
		assert_equal 'Duplicate key __proto__', parse_error("__proto__: 1\n__proto__: 2").reason
	end

	# Strings

	def test_literal_strings_are_literal
		assert_equal 'C:\Users\n\t\u{41}', value_of(%q(a: 'C:\Users\n\t\u{41}'))
	end

	def test_escaped_strings_decode_every_escape
		assert_equal "\\\"\n\t\u0000A😀", value_of(%q(a: "\\\\\"\n\t\u{0}\u{41}\u{1f600}"))
	end

	def test_a_long_escaped_string_with_many_escapes
		assert_equal "x\n" * 10_000, value_of(%(a: "#{'x\n' * 10_000}"))
	end

	def test_a_long_literal_string
		expected = 'é' * 100_000
		assert_equal expected, value_of("a: '#{expected}'")
	end

	def test_block_strings_dedent_by_the_closing_delimiter
		assert_equal "one\n\ttwo", value_of("a: '''\n\t\tone\n\t\t\ttwo\n\t\t'''")
	end

	def test_block_strings_drop_blank_lines_at_the_edges_only
		assert_equal "x\n\ny", value_of("a: '''\n\n\n\tx\n\n\ty\n\n\n\t'''")
	end

	def test_a_blank_line_in_a_block_string_needs_no_indentation_and_becomes_an_empty_line
		assert_equal 'x', value_of("a: '''\n    \n  x\n  '''")
		assert_equal 'x', value_of("a: '''\n  x\n     \n  '''")
		assert_equal "x\n\ny", value_of("a: '''\n  x\n \n  y\n  '''")
		assert_equal "x\n\ny", value_of("a: '''\n\tx\n \t \n\ty\n\t'''")
		assert_equal "x\n\ny", value_of("a: \"\"\"\n\tx\n\t\t\n\ty\n\t\"\"\"")
	end

	def test_a_content_line_indented_less_than_the_closing_delimiter_is_still_an_error
		error = parse_error("a: '''\n\tx\n y\n\t'''")
		assert_match(/indentation of its block string's closing delimiter/, error.reason)
		assert_equal [3, 1], [error.line, error.column]
	end

	def test_escaped_block_strings_decode_escapes_after_dedenting
		assert_equal "\tA", value_of("a: \"\"\"\n\t\\t\\u{41}\n\t\"\"\"")
	end

	def test_an_escape_error_in_a_block_string_points_at_the_escape
		error = parse_error("a: \"\"\"\n\tok\n\t  x\\q\n\t\"\"\"")
		assert_match(/Unknown escape “\\q”/, error.reason)
		assert_equal [3, 5], [error.line, error.column]
	end

	def test_a_block_string_closed_by_a_longer_delimiter_can_hold_the_shorter_run
		assert_equal "'''\n''''", value_of("a: '''''\n\t'''\n\t''''\n\t'''''")
	end

	# Numbers

	def test_int_forms
		assert_same_value [0, 1, -1, 1000, 255, 255, 15, 10, 3_735_928_559], value_of('a: [0, 1, -1, 1_000, 0xFF, 0x00FF, 0o17, 0b1010, 0xDEAD_BEEF]')
	end

	def test_float_forms
		assert_same_value [1.5, 1e10, 10_000.0, 0.0015, -1e-10, 10.5], value_of('a: [1.5, 1e10, 100e2, 1.5e-3, -1e-10, 1_0.5_0]')
	end

	def test_an_exponent_of_zero_has_one_spelling
		assert_same_value 1.0, value_of('a: 1e0')

		error = parse_error('a: 1e-0')
		assert_equal ['“e-0” is not allowed, because an exponent of zero has one spelling: e0', 4], [error.reason, error.column]
	end

	def test_an_exponent_has_no_leading_zeros_like_the_integer_part
		assert_same_value [1.0, 1e5, 1e-5, 1e10, 1.5e10], value_of('a: [1e0, 1e5, 1e-5, 1e1_0, 1.5e10]')

		%w[1e05 1e-05 1e00 1e0_5 1.5e007 -1e-0_1].each do |text|
			error = parse_error("a: #{text}")
			assert_equal ['Leading zeros are not allowed in an exponent', 4], [error.reason, error.column], text
		end
	end

	def test_the_int64_boundaries_in_every_radix
		assert_same_value((2**63) - 1, value_of('a: 0x7FFFFFFFFFFFFFFF'))
		assert_same_value((2**63) - 1, value_of('a: 0o777777777777777777777'))
		assert_same_value((2**63) - 1, value_of("a: 0b#{'1' * 63}"))
		assert_match(/64-bit range/, parse_error('a: 0x8000000000000000').reason)
		assert_match(/64-bit range/, parse_error('a: 0o1000000000000000000000').reason)
		assert_match(/64-bit range/, parse_error("a: 0b1#{'0' * 63}").reason)
	end

	def test_a_float_with_many_digits_rounds_correctly
		assert_same_value 1.0 / 3, value_of("a: 0.#{'3' * 1000}")
		assert_same_value 2.225073858507201e-308, value_of('a: 2.2250738585072011e-308')
	end

	# Note: Not using `Rational#to_f` because it rounds this numerator before dividing, which changes the nearest float (Ruby bug #22246).
	def test_a_decimal_float_is_rounded_once
		assert_same_value 65803600.513127826, value_of('a: 65803600.513127829623')
		assert_same_value 65803600.513127826, value_of('a: 65803600513127829623e-12')
	end

	def test_the_largest_finite_float_and_the_first_one_past_it
		assert_same_value Float::MAX, value_of('a: 1.7976931348623157e308')
		assert_same_value Float::MAX, value_of('a: 1.7976931348623158e308')
		assert_match(/too large/, parse_error('a: 1.7976931348623159e308').reason)
	end

	# Durations

	def test_a_duration_is_a_soml_duration
		value = value_of('a: 90m')
		assert_instance_of SOML::Duration, value
		assert_equal 5_400_000_000_000, value.nanoseconds
		assert_equal '1h30m', value.to_s
	end

	def test_every_duration_unit_in_its_own_length
		{
			'h' => 3_600_000_000_000,
			'm' => 60_000_000_000,
			's' => 1_000_000_000,
			'ms' => 1_000_000,
			'us' => 1000,
			'ns' => 1
		}.each do |unit, length|
			assert_equal 7 * length, value_of("a: 7#{unit}").nanoseconds, unit
		end
	end

	def test_the_duration_int64_bounds_are_exact
		assert_equal((2**63) - 1, value_of('a: 9223372036854775807ns').nanoseconds)
		assert_equal(-(2**63), value_of('a: -9223372036854775808ns').nanoseconds)
		assert_match(/outside the 64-bit range/, parse_error('a: 9223372036854775808ns').reason)
		assert_match(/outside the 64-bit range/, parse_error('a: -9223372036854775809ns').reason)
	end

	def test_a_duration_fraction_is_exact
		assert_equal 5_400_000_000_000, value_of('a: 1.5h').nanoseconds
		assert_equal 1, value_of('a: 0.000000001s').nanoseconds
		assert_equal 3_600_000_500_000, value_of('a: 1h0.5ms').nanoseconds
		assert_equal 1_500_000_000, value_of("a: 1.5#{'0' * 5000}s").nanoseconds
		assert_match(/not a whole number of nanoseconds/, parse_error('a: 0.0000000000001h').reason)
	end

	def test_the_sign_applies_to_the_whole_duration
		assert_equal(-5_400_000_000_000, value_of('a: -1h30m').nanoseconds)
	end

	def test_a_duration_shaped_key_is_a_string
		assert_equal ['1h30m'], SOML.parse('1h30m: 1').keys
	end

	# Instants

	def test_leap_years
		%w[2024 2000 2400 0004].each do |year|
			assert_instance_of Time, value_of("a: #{year}-02-29T00:00:00Z"), year
		end

		%w[1900 2100 2023].each do |year|
			parse_error("a: #{year}-02-29T00:00:00Z")
		end
	end

	def test_every_month_length_in_a_leap_year_and_a_common_year
		lengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

		[[2023, false], [2024, true]].each do |year, is_leap|
			lengths.each_with_index do |length, index|
				month = format('%02d', index + 1)
				last = index == 1 && is_leap ? 29 : length
				assert_equal Time.utc(year, index + 1, last), value_of("a: #{year}-#{month}-#{last}T00:00:00Z")
				assert_match(/day must be 01 to #{last}/, parse_error("a: #{year}-#{month}-#{last + 1}T00:00:00Z").reason)
			end
		end
	end

	def test_the_instant_range_is_checked_in_utc
		assert_match(/outside the years 0001 to 9999/, parse_error('a: 0001-01-01T00:59:59+01:00').reason)
		assert_equal Time.utc(1, 1, 1), value_of('a: 0001-01-01T01:00:00+01:00')
		assert_match(/outside the years 0001 to 9999/, parse_error('a: 9999-12-31T23:00:00-01:00').reason)
		assert_equal instant('9999-12-31T23:59:59.999999999Z'), value_of('a: 9999-12-31T22:59:59.999999999-01:00')
	end

	def test_the_leniency_of_other_date_parsers_is_not_inherited
		%w[2026-09-19t14:00:00Z 2026-09-19T14:00:00z 2026-09-19T14:00:00+0700 2026-12-31T23:59:60Z 2026-09-19T14:00:00.1234567891Z 2026-09-19T14:00:00-00:00].each do |value|
			assert_raises(SOML::ParseError, value) { SOML.parse("a: #{value}") }
		end
	end

	# Nesting limit

	def test_100_nested_arrays_are_accepted
		value = SOML.parse("#{'[' * 100}#{']' * 100}")
		depth = 0

		while value.is_a?(Array)
			depth += 1
			value = value[0]
		end

		assert_equal 100, depth
	end

	def test_101_nested_arrays_are_rejected_with_a_parse_error_not_a_stack_overflow
		assert_equal 'The document is nested more than 100 levels deep', parse_error("#{'[' * 101}#{']' * 101}").reason
	end

	def test_nested_objects_count_the_same_way
		assert_equal ['a'], SOML.parse("#{'a: {' * 99}#{'}' * 99}").keys
		assert_match(/nested more than 100/, parse_error("#{'a: {' * 100}#{'}' * 100}").reason)
	end

	def test_an_unclosed_deep_document_fails_cleanly
		parse_error('[' * 100_000)
		parse_error('a: ' * 100_000)
	end

	def test_what_parses_at_the_limit_also_generates
		value = SOML.parse("#{'[' * 100}#{']' * 100}")
		assert_equal 1, SOML.parse(SOML.generate(value)).length
	end

	# Examples from the readme, the comparison, and the spec. The documentation is in the specification repository, and these tests are skipped when it is not checked out next to this one.

	SPECIFICATION = File.join(__dir__, '../../soml')
	DOCUMENTATION = Dir.exist?(SPECIFICATION) ? %w[readme.md comparison.md spec.md].map { File.read(File.join(SPECIFICATION, it)) }.join("\n") : ''

	# The untagged blocks, and each SOML example with the JSON example that directly follows it, which hold the same data.
	BLOCKS, JSON_PAIRS = begin
		blocks = []
		json_pairs = []
		current = nil
		previous_tag = nil

		DOCUMENTATION.split("\n").each do |line|
			if line.start_with?('```')
				if current.nil?
					current = {tag: line[3..].strip, lines: []}
				else
					text = "#{current[:lines].join("\n")}\n"

					if current[:tag].empty?
						blocks << text
					elsif previous_tag == '' && current[:tag] == 'json'
						json_pairs << {soml: blocks.last, json: text}
					end

					previous_tag = current[:tag]
					current = nil
				end
			elsif current
				current[:lines] << line
			end
		end

		[blocks.freeze, json_pairs.freeze]
	end

	# Blocks that are not documents: the `.gitattributes` line, the escape list, and the grammar.
	DOCUMENT_BLOCKS = BLOCKS.reject { it.start_with?('* text', '\u{0}', '; whitespace', 'document    =') }

	def test_the_documentation_has_untagged_example_blocks
		skip 'The specification repository is not next to this one' unless Dir.exist?(SPECIFICATION)

		assert_operator BLOCKS.length, :>, 10
	end

	DOCUMENT_BLOCKS.each_with_index do |block, index|
		define_method("test_documentation_example_#{index}_parses: #{block.lines.first.chomp}") do
			value = SOML.parse(block)
			assert_same_value value, SOML.parse(SOML.generate(value))
		end
	end

	# The documentation block that starts with `prefix`, or a skip when the specification repository is not there.
	def documentation_block(prefix)
		skip 'The specification repository is not next to this one' unless Dir.exist?(SPECIFICATION)

		BLOCKS.find { it.start_with?(prefix) }
	end

	def edge_service_example
		documentation_block('# The edge service')
	end

	def test_the_edge_service_example
		assert_same_value({
			'name' => 'api-gateway',
			'version' => '2.1.0',
			'pattern' => '^\d{4}-\d{2}-\d{2}$',
			'windows-path' => 'C:\Users\sindre\dev',
			'content-security-policy' => "default-src 'self'; script-src https://cdn.example.com",
			'replicas' => 3,
			'timeout' => duration(30_000_000_000),
			'drained' => false,
			'owner' => nil,
			'deployed-at' => instant('2026-09-19T14:00:00Z'),
			'labels' => %w[prod eu-west canary],
			'description' => "The API gateway terminates TLS.\nIt routes requests to internal services.\nIt has no external dependencies.",
			'postgres' => {'host' => 'db.internal', 'port' => 5432, 'ssl' => true}
		}, SOML.parse(edge_service_example))
	end

	# JSON has no int, duration, or instant, so its files write a number, the seconds as a number, and a string. A comparison with `==` does not tell `30` from `30.0`, as JSON does not.
	def json_value(value)
		case value
		when Hash
			value.transform_values { json_value(it) }
		when Array
			value.map { json_value(it) }
		when SOML::Duration
			value.to_f
		when Time
			value.iso8601.encode(Encoding::UTF_8)
		else
			value
		end
	end

	def test_each_json_example_holds_the_same_data_as_the_soml_example_before_it_apart_from_types_json_lacks
		skip 'The specification repository is not next to this one' unless Dir.exist?(SPECIFICATION)

		assert_operator JSON_PAIRS.length, :>=, 2

		JSON_PAIRS.each do |pair|
			assert_equal JSON.parse(pair[:json]), json_value(SOML.parse(pair[:soml])), pair[:soml]
		end
	end

	def test_the_every_feature_example
		value = SOML.parse(documentation_block("/*\nEverything SOML can express"))
		assert_same_value 'soml', value['name']
		assert_same_value 'and a key may begin with a digit', value['404']
		assert_same_value "line one\nline two\t\"quoted\"😀", value['escaped']
		assert_same_value 0b1010_1100, value['mask']
		assert_same_value 0o644, value['permissions']
		assert_same_value 0xFF_88_00, value['color']
		assert_same_value Float::INFINITY, value['limit']
		assert_same_value [{'name' => 'Sindre Sorhus', 'email' => 'sindresorhus@gmail.com'}, {'name' => 'Random Person', 'email' => 'person@example.com'}], value['maintainers']
		assert_same_value duration(90_000_000_000), value['retry-after']
		assert_same_value({'path' => '/health', 'interval' => duration(10_000_000_000), 'grace' => duration(1_500_000_000)}, value['healthcheck'])
	end

	# Huge tokens. JS uses 5,000,000 characters, past what a regex with a repeated group can handle there. Onigmo keeps about 50 bytes per repeated character on the heap instead, so a length here only needs to be past the 1,000 characters that the parser reads to explain an invalid token. `test_complexity.rb` checks that the time grows linearly with the length.

	HUGE_LENGTH = 10_000

	def test_a_huge_valid_float
		assert_same_value 0.1111111111111111, value_of("a: 0.#{'1' * HUGE_LENGTH}")
	end

	def test_a_huge_hexadecimal_int_with_leading_zeros
		assert_same_value 255, value_of("a: 0x#{'0' * HUGE_LENGTH}FF")
	end

	def test_huge_out_of_range_ints
		{
			"a: #{'1' * HUGE_LENGTH}" => "1#{'1' * 39}…",
			"a: 0x#{'F' * HUGE_LENGTH}" => "0x#{'F' * 38}…",
			"a: 0b#{'1_' * (HUGE_LENGTH / 2)}1" => "0b#{'1_' * 19}…"
		}.each do |source, integer|
			assert_equal "The integer #{integer} is outside the 64-bit range (-9223372036854775808 to 9223372036854775807)", parse_error(source).reason
		end
	end

	def test_huge_invalid_numbers_and_instants
		assert_equal 'An underscore in a number must be between two digits', parse_error("a: 1#{'_' * HUGE_LENGTH}").reason
		assert_equal "Invalid number “1#{'x' * 39}…”. A string value must be quoted, as in '1#{'x' * 39}…'", parse_error("a: 1#{'x' * HUGE_LENGTH}").reason
		assert_equal "Invalid number “1.#{'2' * 38}…”", parse_error("a: 1.#{'2' * HUGE_LENGTH}.3").reason
		assert_equal "Invalid instant “2026-01-01T00:00:00.#{'1' * 20}…”. An instant is written as 2026-09-19T14:00:00Z, with an optional fraction of up to nine digits and an offset of Z or ±HH:MM", parse_error("a: 2026-01-01T00:00:00.#{'1' * HUGE_LENGTH}Z").reason
	end

	def test_a_huge_bare_key_as_a_duplicate_and_through_generate
		key = 'k' * HUGE_LENGTH
		assert_equal "Duplicate key #{'k' * 40}…", parse_error("#{key}: 1\n#{key}: 2").reason
		assert_equal HUGE_LENGTH + 4, SOML.generate(SOML.parse("#{key}: 1")).length
	end

	def test_error_messages_quote_at_most_40_characters_of_a_token
		error = parse_error("a: #{'x' * HUGE_LENGTH}")
		assert_equal "Unexpected “#{'x' * 40}…”. A string value must be quoted, as in '#{'x' * 40}…'", error.reason
		assert_operator error.message.length, :<, 1000
	end

	# UTF-8 details

	def test_a_utf8_sequence_cut_short_by_the_end_of_the_input
		error = parse_error("a: 1 #\xE2\x82".b)
		assert_equal ['Incomplete UTF-8 sequence at the end of the input', 1, 7], [error.reason, error.line, error.column]
	end

	def test_a_cut_utf8_sequence_that_is_not_at_the_end_is_invalid_not_incomplete
		assert_equal 'Invalid UTF-8 byte 0xE2', parse_error("a: '\xE2\x82'".b).reason
		assert_equal 'Invalid UTF-8 byte 0xF0', parse_error("a: '\xF0\x9F\x98'".b).reason
	end

	# The escape is read from a byte slice that can cut the next character in two.
	def test_a_unicode_escape_followed_by_a_multibyte_character
		assert_equal({'a' => '😀😀'}, SOML.parse('a: "\\u{1f600}😀"'))
		assert_equal 'A Unicode escape is written \\u{…} with one to six lowercase hexadecimal digits', parse_error('a: "\\u{😀}"').reason
		assert_equal 'A Unicode escape is written \\u{…} with one to six lowercase hexadecimal digits', parse_error('a: "\\u{1é😀😀😀"').reason
	end

	# 2^53 + 1 is halfway between two floats. With only zeros after it, the tie goes to the even one. With a 1 far after it, the value is above halfway, so it rounds up, and that 1 is past the 800 digits that are read.
	def test_a_float_with_more_than_800_digits_rounds_correctly
		halfway = '9007199254740993'
		assert_same_value({'a' => 9_007_199_254_740_992.0}, SOML.parse("a: #{halfway}.#{'0' * 900}"))
		assert_same_value({'a' => 9_007_199_254_740_994.0}, SOML.parse("a: #{halfway}.#{'0' * 900}1"))
		assert_same_value({'a' => 9_007_199_254_740_994.0}, SOML.parse("a: #{halfway}#{'0' * 900}1e-901"))
		assert_same_value({'a' => 9_007_199_254_740_992.0}, SOML.parse("a: #{halfway}#{'0' * 900}e-900"))
	end
end
