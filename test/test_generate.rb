# frozen_string_literal: true

# Unit tests for `SOML.generate`, ported from soml-js's `test/stringify.ts`, and the round trips of `test/round-trip.ts` that do not need a random document generator.
#
# The JS tests that do not apply to Ruby are left out: `undefined`, holes, getters, non-enumerable and symbol-keyed properties, null prototypes, realms, `toJSON`, `Date`, the `Temporal` brand checks, calendar units in a duration, and the `integers` option. `compareKeys` and `isBareKey` are not part of the Ruby API, so their cases are checked through `generate`. Every refusal is a `SOML::GenerateError`, where JS throws a `TypeError` or a `RangeError`.

require_relative 'test_helper'
require 'date'
require 'time'

class TestGenerate < Minitest::Test
	BARE_KEY = /\A[A-Za-z0-9_-]+\z/

	Point = Struct.new(:x)

	def instant(text)
		Time.iso8601(text)
	end

	def duration(nanoseconds)
		SOML::Duration.new(nanoseconds:)
	end

	def nested_arrays(depth)
		value = []

		(depth - 1).times do
			value = [value]
		end

		value
	end

	def nested_hashes(depth)
		value = {}

		(depth - 1).times do
			value = {'a' => value}
		end

		value
	end

	# Layout

	def test_a_top_level_object_has_no_braces_and_no_indentation
		assert_equal "a: 1\nb: 'x'\n", SOML.generate({'a' => 1, 'b' => 'x'})
	end

	def test_a_top_level_array
		assert_equal "[\n\t1\n\t'x'\n]\n", SOML.generate([1, 'x'])
	end

	def test_an_empty_top_level_object_keeps_its_braces
		assert_equal "{}\n", SOML.generate({})
	end

	def test_an_empty_top_level_array
		assert_equal "[]\n", SOML.generate([])
	end

	def test_nesting_is_one_tab_per_level_and_writes_no_commas
		assert_equal "a: {\n\tb: [\n\t\t1\n\t\t{\n\t\t\tc: []\n\t\t}\n\t]\n}\n", SOML.generate({'a' => {'b' => [1, {'c' => []}]}})
	end

	def test_empty_nested_containers_are_written_on_one_line
		assert_equal "a: {}\nb: []\n", SOML.generate({'a' => {}, 'b' => []})
		assert_equal "[\n\t[]\n\t{}\n]\n", SOML.generate([[], {}])
	end

	def test_the_output_ends_with_exactly_one_line_feed
		[{'a' => 1}, [], {}, [[]], {'a' => {'b' => {}}}].each do |value|
			output = SOML.generate(value)
			assert output.end_with?("\n"), value.inspect
			refute output.end_with?("\n\n"), value.inspect
		end
	end

	def test_the_output_is_a_utf8_string
		assert_equal Encoding::UTF_8, SOML.generate({'a' => 'x'}).encoding
		assert_equal Encoding::UTF_8, SOML.generate({}).encoding
		assert_equal Encoding::UTF_8, SOML.generate({'a' => "\xC3\xA9".b}).encoding
		assert_equal Encoding::UTF_8, SOML.generate({'a' => 'é'.encode(Encoding::UTF_16LE)}).encoding
	end

	def test_the_output_is_not_frozen
		refute_predicate SOML.generate({'a' => 1}), :frozen?
		refute_predicate SOML.generate({}), :frozen?
	end

	# Key order

	def test_members_keep_the_order_of_their_hash
		assert_equal "b: 1\na: 2\nc: 3\n", SOML.generate({'b' => 1, 'a' => 2, 'c' => 3})
		assert_equal "name: 'api'\ndescription: 'x'\n", SOML.generate({name: 'api', description: 'x'})
	end

	def test_nested_members_keep_the_order_of_their_hash
		assert_equal "z: {\n\tb: 1\n\ta: 2\n}\na: [\n\t{\n\t\ty: 1\n\t\tx: 2\n\t}\n]\n", SOML.generate({'z' => {'b' => 1, 'a' => 2}, 'a' => [{'y' => 1, 'x' => 2}]})
	end

	def test_the_order_of_the_hash_is_canonical_form_when_it_is_sorted
		value = {'a' => {'b' => 1, 'c' => [1.0, {'d' => "x'"}]}, 'e' => SOML::Duration.parse('90m')}
		assert_equal SOML.generate(value, canonical: true), SOML.generate(value)
	end

	def test_members_are_sorted_by_key
		assert_equal "a: 2\nb: 1\nc: 3\n", SOML.generate({'b' => 1, 'a' => 2, 'c' => 3}, canonical: true)
	end

	def test_integer_like_keys_are_sorted_as_strings
		assert_equal "1: 4\n10: 2\n9: 3\nb: 1\n", SOML.generate({'b' => 1, '10' => 2, '9' => 3, '1' => 4}, canonical: true)
	end

	def test_sorting_compares_code_points
		# U+FF61 is one UTF-16 code unit, and U+1F600 is a surrogate pair starting with 0xD83D, so UTF-16 code unit order would put the emoji first.
		assert_equal "'\u{FF61}': 2\n'😀': 1\n", SOML.generate({'😀' => 1, "\u{FF61}" => 2}, canonical: true)
		assert_equal "z: 5\n'\u{D7FF}': 4\n'\u{E000}': 3\n'\u{FFFF}': 2\n'\u{10000}': 1\n", SOML.generate({"\u{10000}" => 1, "\u{FFFF}" => 2, "\u{E000}" => 3, "\u{D7FF}" => 4, 'z' => 5}, canonical: true)
	end

	def test_two_astral_keys_are_compared_by_code_point
		assert_equal "'\u{1F600}': 2\n'\u{1F601}': 1\n'\u{20000}': 3\n", SOML.generate({"\u{1F601}" => 1, "\u{1F600}" => 2, "\u{20000}" => 3}, canonical: true)
	end

	def test_keys_are_ordered_by_code_point_so_u_fffd_comes_before_an_astral_character
		value = ['b', '😀', 'a', "\u{FFFD}", "\u{E000}", 'ab', ''].to_h { [it, 1] }
		assert_equal ['', 'a', 'ab', 'b', "\u{E000}", "\u{FFFD}", '😀'], SOML.parse(SOML.generate(value, canonical: true)).keys
	end

	def test_keys_in_other_encodings_are_ordered_by_their_utf8_code_points
		value = {"\xE9".dup.force_encoding(Encoding::Windows_1252) => 1, 'z'.encode(Encoding::UTF_16LE) => 2, 'a'.b => 3}
		assert_equal "a: 3\nz: 2\n'é': 1\n", SOML.generate(value, canonical: true)
	end

	def test_a_key_that_is_a_prefix_of_another_comes_first
		assert_equal "a: 2\na-b: 3\nab: 1\n", SOML.generate({'ab' => 1, 'a' => 2, 'a-b' => 3}, canonical: true)
	end

	def test_nested_objects_are_sorted_too
		assert_equal "z: {\n\ta: 2\n\tb: 1\n}\n", SOML.generate({'z' => {'b' => 1, 'a' => 2}}, canonical: true)
		assert_equal "a: [\n\t{\n\t\tx: 2\n\t\ty: 1\n\t}\n]\nz: {}\n", SOML.generate({'z' => {}, 'a' => [{'y' => 1, 'x' => 2}]}, canonical: true)
	end

	def test_arrays_keep_their_order
		assert_equal "[\n\t3\n\t1\n\t2\n]\n", SOML.generate([3, 1, 2])
	end

	# Keys

	def test_generate_writes_exactly_the_bare_keys_bare
		['a', 'Z', '0', '_', '-', '.', ' ', '', '$ref', "'", '"', '\\', "\n", "\t", "\u0000", "\u007F", "\u0080", 'é', "\u2028", "\u{10FFFF}", '#', ':', ',', '{', ']', 'a-B_9', 'a b', 'ab.c', '😀x', 'x😀'].each do |key|
			assert_equal key.match?(BARE_KEY), SOML.generate({key => 1}).start_with?("#{key}: "), key.inspect
		end
	end

	def test_keys_are_bare_when_every_character_is_a_letter_digit_underscore_or_dash
		assert_equal "content-type: 1\n_x: 2\n404: 3\n-: 4\n", SOML.generate({'content-type' => 1, '_x' => 2, '404' => 3, '-' => 4})
	end

	def test_keys_are_quoted_otherwise
		assert_equal "'a b': 1\n", SOML.generate({'a b' => 1})
		assert_equal "'a.b': 1\n", SOML.generate({'a.b' => 1})
		assert_equal "'': 1\n", SOML.generate({'' => 1})
		assert_equal "'café': 1\n", SOML.generate({'café' => 1})
		assert_equal "\"it's\": 1\n", SOML.generate({"it's" => 1})
		assert_equal "\"a\\tb\": 1\n", SOML.generate({"a\tb" => 1})
	end

	def test_keywords_and_number_like_keys_are_bare
		assert_equal "true: 1\nnull: 2\ninfinity: 3\n1000: 4\n", SOML.generate({'true' => 1, 'null' => 2, 'infinity' => 3, '1000' => 4})
	end

	def test_a_proto_key_round_trips_as_a_plain_key
		assert_equal "__proto__: {\n\ta: 1\n}\n", SOML.generate(SOML.parse('__proto__: {a: 1}'))
	end

	def test_symbol_keys_are_written_as_strings
		assert_equal "b: 2\na: 1\n", SOML.generate({b: 2, 'a' => 1})
		assert_equal "a: 1\nb: 2\n", SOML.generate({b: 2, 'a' => 1}, canonical: true)
		assert_equal "'a b': 1\n", SOML.generate({'a b': 1})
		assert_equal "nested: {\n\tx: 1\n}\n", SOML.generate({nested: {x: 1}})
	end

	def test_symbolized_keys_round_trip
		value = SOML.parse("a: {b: 1}\nc: [{d: 'x'}]", symbolize_names: true)
		assert_equal "a: {\n\tb: 1\n}\nc: [\n\t{\n\t\td: 'x'\n\t}\n]\n", SOML.generate(value)
	end

	def test_a_symbol_key_and_a_string_key_with_the_same_name_are_a_duplicate
		error = generate_error({a: 1, 'a' => 2})
		# A key is shown as the errors of `parse` show it, bare when it can be.
		assert_equal "Cannot generate the key a twice, because two keys, such as :a and 'a', are the same string", error.message
		assert_equal ['nested'], generate_error({'nested' => {'b' => 1, b: 2}}).path
	end

	def test_a_key_that_is_not_a_string_or_a_symbol_is_refused_rather_than_converted
		[1, 1.5, nil, true, [1], Time.at(0)].each do |key|
			assert_match(/key/, generate_error({key => 1}).message, key.inspect)
		end

		generate_error({'a' => {1 => 'x'}})
	end

	def test_a_key_that_is_not_valid_utf8_is_refused
		["\xFF", "a\xC3", "\xED\xA0\x80", "\xFF".b].each do |key|
			assert_match(/not valid UTF-8/, generate_error({key => 1}).message, key.inspect)
		end
	end

	def test_a_key_in_another_encoding_is_converted_to_utf8
		assert_equal "'é': 1\n", SOML.generate({'é'.encode(Encoding::UTF_16LE) => 1})
		assert_equal "'é': 1\n", SOML.generate({"\xC3\xA9".b => 1})
	end

	def test_a_key_with_a_line_feed_is_written_as_an_escaped_string
		assert_equal "\"a\\nb\": 1\n", SOML.generate({"a\nb" => 1})
		assert_equal "nested: {\n\t\"\\n\": 1\n}\n", SOML.generate({'nested' => {"\n" => 1}})
	end

	def test_a_key_with_a_carriage_return_is_refused
		assert_match(/because it contains a carriage return/, generate_error({"a\rb" => 1}).message)
		assert_match(/because it contains a carriage return/, generate_error({"a\rb": 1}).message)
	end

	# Strings

	def test_strings_are_literal_by_default
		assert_equal "a: 'x'\n", SOML.generate({'a' => 'x'})
		assert_equal "a: ''\n", SOML.generate({'a' => ''})
	end

	def test_backslashes_and_double_quotes_stay_literal
		assert_equal "a: 'C:\\Users\\x'\n", SOML.generate({'a' => 'C:\Users\x'})
		assert_equal "a: 'say \"hi\"'\n", SOML.generate({'a' => 'say "hi"'})
	end

	def test_a_single_quote_switches_to_an_escaped_string
		assert_equal "a: \"it's\"\n", SOML.generate({'a' => "it's"})
		assert_equal "a: \"it's \\\"x\\\" \\\\\"\n", SOML.generate({'a' => "it's \"x\" \\"})
	end

	def test_control_characters_switch_to_an_escaped_string
		assert_equal "a: \"a\\nb\"\n", SOML.generate({'a' => "a\nb"})
		assert_equal "a: \"a\\tb\"\n", SOML.generate({'a' => "a\tb"})
		assert_equal "a: \"\\u{0}\"\n", SOML.generate({'a' => "\u0000"})
		assert_equal "a: \"\\u{1f}\"\n", SOML.generate({'a' => "\u001F"})
		assert_equal "a: \"\\u{7f}\"\n", SOML.generate({'a' => "\u007F"})
		assert_equal "a: \"\\u{8}\\u{b}\\u{c}\"\n", SOML.generate({'a' => "\b\v\f"})
	end

	def test_every_c0_control_character_is_escaped_in_the_shortest_lowercase_form
		(0...0x20).each do |code|
			next if code == 0x0D

			expected = {0x0A => '\n', 0x09 => '\t'}.fetch(code) { "\\u{#{code.to_s(16)}}" }
			assert_equal "a: \"#{expected}\"\n", SOML.generate({'a' => code.chr(Encoding::UTF_8)}), code.to_s
		end
	end

	def test_everything_else_is_written_literally
		text = "\u0080\u0085\u009F\u00A0\u2028\u2029\uFEFF\uFFFE\uFFFF\u{10FFFF}é😀日本"
		assert_equal "a: '#{text}'\n", SOML.generate({'a' => text})
	end

	# A lone surrogate cannot be in a valid UTF-8 string, so the JS lone surrogate checks are invalid UTF-8 here.
	def test_a_string_that_is_not_valid_utf8_is_refused
		["\xED\xA0\x80", "\xED\xBF\xBF", "a\xED\xA0\xBD", "\xFF", "a\xC3", "\xC3".b].each do |text|
			assert_match(/string that is not valid UTF-8/, generate_error({'a' => text}).message, text.inspect)
		end
	end

	def test_a_binary_string_that_is_valid_utf8_is_written_as_utf8
		assert_equal "a: 'é'\n", SOML.generate({'a' => "\xC3\xA9".b})
	end

	def test_a_string_in_another_encoding_is_converted_to_utf8
		assert_equal "a: 'é😀'\n", SOML.generate({'a' => 'é😀'.encode(Encoding::UTF_16LE)})
		assert_equal "a: 'é'\n", SOML.generate({'a' => "\xE9".dup.force_encoding(Encoding::Windows_1252)})
		assert_equal "a: 'x'\n", SOML.generate({'a' => 'x'.encode(Encoding::US_ASCII)})
	end

	def test_a_string_that_cannot_be_converted_to_utf8_is_refused
		text = 'a'.encode(Encoding::UTF_16LE) + "\x00\xD8".dup.force_encoding(Encoding::UTF_16LE)
		# The text after the colon is Ruby's own message, which a later Ruby may word differently.
		assert_match(/\ACannot generate a string that cannot be converted to UTF-8: ./, generate_error({'a' => text}).reason)
		assert_match(/\ACannot generate a key that cannot be converted to UTF-8: ./, generate_error({text => 1}).reason)
	end

	def test_a_symbol_value_is_written_as_a_string
		assert_equal "a: 'b'\n", SOML.generate({'a' => :b})
		assert_equal "a: \"it's\"\n", SOML.generate({'a' => :"it's"})
		assert_equal "[\n\t'x'\n]\n", SOML.generate([:x])
	end

	def test_a_string_with_a_carriage_return_is_refused
		assert_match(/carriage return/, generate_error({'a' => "a\r\nb"}).message)
		generate_error(["\r"])
		generate_error({'a' => :"\r"})
	end

	def test_block_strings_are_never_written
		assert_equal "a: \"x\\ny\"\n", SOML.generate(SOML.parse("a: '''\n\tx\n\ty\n\t'''"))
	end

	# Integers

	def test_an_integer_is_an_int
		assert_equal "a: 0\nb: -1\nc: 255\n", SOML.generate({'a' => 0, 'b' => -1, 'c' => 255})
	end

	def test_the_int64_bounds
		assert_equal "a: 9223372036854775807\nb: -9223372036854775808\n", SOML.generate({'a' => (2**63) - 1, 'b' => -(2**63)})
	end

	def test_an_integer_outside_int64_is_refused
		assert_equal 'Cannot generate the integer 9223372036854775808, because it is outside the 64-bit range', generate_error({'a' => 2**63}).reason
		assert_equal 'Cannot generate the integer -9223372036854775809, because it is outside the 64-bit range', generate_error({'a' => -(2**63) - 1}).reason
		generate_error([2**100])
	end

	# Floats

	FLOAT_CASES = [
		[0.0, '0.0'],
		[-0.0, '0.0'],
		[1.0, '1.0'],
		[-1.0, '-1.0'],
		[30.0, '30.0'],
		[1.5, '1.5'],
		[0.1, '0.1'],
		[0.1 + 0.2, '0.30000000000000004'],
		[1e20, '100000000000000000000.0'],
		[1e21, '1e21'],
		[1.5e21, '1.5e21'],
		[-1e21, '-1e21'],
		[1e-6, '0.000001'],
		[1e-7, '1e-7'],
		[1.5e-7, '1.5e-7'],
		[123_456_789_012_345_680_000.0, '123456789012345680000.0'],
		[Float::MAX, '1.7976931348623157e308'],
		[5e-324, '5e-324'],
		[Float::EPSILON, '2.220446049250313e-16'],
		[9_007_199_254_740_991.0, '9007199254740991.0'],
		[2.0**53, '9007199254740992.0'],
		[Math::PI, '3.141592653589793'],
		[Float::INFINITY, 'infinity'],
		[-Float::INFINITY, '-infinity']
	].freeze

	FLOAT_CASES.each do |value, expected|
		define_method("test_the_float #{value.zero? && 1.0 / value < 0 ? '-0.0' : value} is written as #{expected}") do
			assert_equal "a: #{expected}\n", SOML.generate({'a' => value})
		end
	end

	def test_float_layout_switches_to_an_exponent_where_ecmascript_does
		assert_equal "a: 10000000000000000.0\n", SOML.generate({'a' => 1e16})
		assert_equal "a: 0.0001\n", SOML.generate({'a' => 1e-4})
		assert_equal "a: 0.00001\n", SOML.generate({'a' => 1e-5})
		assert_equal "a: 1.5e300\n", SOML.generate({'a' => 1.5e300})
		assert_equal "a: 1.2345678901234568e-7\n", SOML.generate({'a' => 1.2345678901234568e-7})
		assert_equal "a: 999999999999999900000.0\n", SOML.generate({'a' => 999_999_999_999_999_900_000.0})
	end

	def test_nan_is_refused
		assert_match(/NaN/, generate_error({'a' => Float::NAN}).message)
		generate_error([Float::NAN])
	end

	def test_the_output_never_reads_back_as_an_int
		[0.0, 1.0, 1e15, 1e20, 1e21, 1e300, -5.0].each do |value|
			assert_instance_of Float, SOML.parse(SOML.generate({'a' => value}))['a'], value.to_s
		end
	end

	# Instants

	def test_a_time_is_written_in_utc
		assert_equal "a: 2026-09-19T07:00:00Z\n", SOML.generate({'a' => Time.new(2026, 9, 19, 14, 0, 0, '+07:00')})
		assert_equal "a: 2026-09-19T07:00:00Z\n", SOML.generate({'a' => instant('2026-09-19T14:00:00+07:00')})
		assert_equal "a: 2026-09-19T16:30:00Z\n", SOML.generate({'a' => Time.new(2026, 9, 19, 14, 0, 0, '-02:30')})
	end

	def test_a_local_time_is_written_in_utc
		time = Time.at(0)
		assert_equal "a: 1970-01-01T00:00:00Z\n", SOML.generate({'a' => time})
		assert_equal "a: 1970-01-01T00:00:00Z\n", SOML.generate({'a' => time.localtime('+05:00')})
	end

	def test_generate_does_not_change_the_time
		time = Time.new(2026, 9, 19, 14, 0, 0, '+07:00')
		SOML.generate({'a' => time})
		assert_equal 25_200, time.utc_offset
		refute_predicate time, :utc?
	end

	def test_the_fraction_drops_trailing_zeros_and_is_left_out_when_zero
		assert_equal "a: 2026-09-19T14:00:00.1Z\n", SOML.generate({'a' => instant('2026-09-19T14:00:00.100Z')})
		assert_equal "a: 2026-09-19T14:00:00Z\n", SOML.generate({'a' => instant('2026-09-19T14:00:00.000Z')})
		assert_equal "a: 2026-09-19T14:00:00.000000001Z\n", SOML.generate({'a' => instant('2026-09-19T14:00:00.000000001Z')})
		assert_equal "a: 1970-01-01T00:00:00.25Z\n", SOML.generate({'a' => Time.at(Rational(1, 4))})
	end

	def test_a_time_with_a_fraction_finer_than_a_nanosecond_is_refused
		time = Time.at(Rational(1, 3_000_000_000), in: 'UTC')
		assert_equal "Cannot generate the instant #{time.inspect}, because it has a fraction of a second finer than a nanosecond. Round it to nanoseconds with time.round(9)", generate_error({'a' => time}).reason
		generate_error({'a' => Time.at(0, Rational(1, 2), :nsec)})
	end

	def test_an_instant_outside_the_years_0001_to_9999_is_refused
		[Time.utc(0, 12, 31, 23, 59, 59), Time.utc(10_000, 1, 1)].each do |time|
			assert_equal "Cannot generate the instant #{time.inspect}, because in UTC it falls outside the years 0001 to 9999", generate_error({'a' => time}).reason
		end
		generate_error({'a' => Time.at(-62_135_596_800 - Rational(1, 1000))})
		assert_equal "a: 0001-01-01T00:00:00Z\n", SOML.generate({'a' => Time.at(-62_135_596_800)})
	end

	def test_the_instant_range_is_checked_in_utc
		generate_error({'a' => Time.new(1, 1, 1, 0, 30, 0, '+01:00')})
		generate_error({'a' => Time.new(9999, 12, 31, 23, 30, 0, '-01:00')})
		assert_equal "a: 0001-01-01T00:00:00Z\n", SOML.generate({'a' => Time.new(1, 1, 1, 1, 0, 0, '+01:00')})
	end

	def test_the_instant_range_bounds
		assert_equal "a: 0001-01-01T00:00:00Z\nb: 9999-12-31T23:59:59.999999999Z\n", SOML.generate({'a' => instant('0001-01-01T00:00:00Z'), 'b' => instant('9999-12-31T23:59:59.999999999Z')})
	end

	def test_a_date_is_refused_because_it_is_not_an_instant
		assert_equal "Cannot generate a Date, because a date is not an instant. Write it as a String, such as '2026-09-19'", generate_error({'a' => Date.new(2026, 9, 19)}).reason
		assert_equal 'Cannot generate a DateTime. Convert it to a Time with to_time', generate_error({'a' => DateTime.new(2026, 9, 19, 14)}).reason
	end

	# Durations

	def test_a_duration_is_written_in_canonical_form
		assert_equal "a: 1h30m\n", SOML.generate({'a' => duration(90 * 60_000_000_000)})
		assert_equal "a: 1.5s\n", SOML.generate({'a' => duration(1_500_000_000)})
		assert_equal "a: 1h0.000000001s\n", SOML.generate({'a' => duration(3_600_000_000_001)})
		assert_equal "a: 0.00025s\n", SOML.generate({'a' => duration(250_000)})
		assert_equal "a: 1m0.1s\n", SOML.generate({'a' => duration(60_100_000_000)})
		assert_equal "a: -5m\n", SOML.generate({'a' => duration(-300_000_000_000)})
		assert_equal "a: 0s\n", SOML.generate({'a' => duration(0)})
	end

	def test_the_duration_int64_bounds
		assert_equal "a: 2562047h47m16.854775807s\n", SOML.generate({'a' => duration((2**63) - 1)})
		assert_equal "a: -2562047h47m16.854775808s\n", SOML.generate({'a' => duration(-(2**63))})
	end

	# Other values

	def test_booleans_and_nil
		assert_equal "a: true\nb: false\nc: null\n", SOML.generate({'a' => true, 'b' => false, 'c' => nil})
	end

	def test_nil_in_an_array_is_null
		assert_equal "[\n\t1\n\tnull\n]\n", SOML.generate([1, nil])
	end

	def test_unsupported_values_are_refused_with_a_message_that_names_them
		{
			-> {} => 'Proc',
			method(:puts) => 'Method',
			Object.new => 'Object',
			Set[1] => 'Set',
			Point.new(1) => 'Point',
			/x/ => 'Regexp',
			(1..2) => 'Range',
			Rational(1, 3) => 'Rational',
			Complex(1, 2) => 'Complex',
			Date.new(2026, 1, 1) => 'Date',
			Class.new => 'Class',
			Kernel => 'Module',
			Encoding::UTF_8 => 'Encoding'
		}.each do |value, name|
			assert_match(/#{name}/, generate_error({'a' => value}).message, value.inspect)
		end

		assert_equal 'Cannot generate a Rational. Convert it to an Integer or a Float', generate_error({'a' => Rational(1, 3)}).reason
	end

	# A value that has a conversion to a type that can be written gets a hint to use it. It is not converted, because the value would not read back as the same class.
	def test_a_value_with_a_conversion_gets_a_hint
		{
			Point.new(1) => 'Cannot generate a TestGenerate::Point. Convert it to a Hash with to_h',
			Struct.new(:x).new(1) => 'Cannot generate an anonymous Struct. Convert it to a Hash with to_h',
			Data.define(:x).new(x: 1) => 'Cannot generate an anonymous Data. Convert it to a Hash with to_h',
			Set[1] => 'Cannot generate a Set. Convert it to an Array with to_a',
			Pathname('/x') => 'Cannot generate a Pathname. Convert it to a String with to_s'
		}.each do |value, reason|
			assert_equal reason, generate_error({'a' => value}).reason, value.inspect
		end
	end

	# An anonymous class is named by its nearest named superclass.
	def test_an_instance_of_an_anonymous_class_is_refused
		assert_equal 'Cannot generate an anonymous Object. Only Hash, Array, String, Symbol, Integer, Float, true, false, nil, Time, and SOML::Duration can be generated', generate_error({'a' => Class.new.new}).reason
		assert_equal 'Cannot generate an anonymous Set. Convert it to an Array with to_a', generate_error({'a' => Class.new(Set).new([1])}).reason
		hash = {}.compare_by_identity
		hash[Class.new(BasicObject).new] = 1
		assert_equal 'A key must be a String or a Symbol, not an anonymous BasicObject, because a key is never converted', generate_error(hash).reason
	end

	# A class may define its own `name` or `to_s`, which can return anything. The error names the class as Ruby does.
	class OwnName
		def self.name = 42
		def self.to_s = nil
	end

	def test_a_class_with_its_own_name_method_is_named_as_ruby_names_it
		assert_equal 'Cannot generate a TestGenerate::OwnName. Only Hash, Array, String, Symbol, Integer, Float, true, false, nil, Time, and SOML::Duration can be generated', generate_error({'a' => OwnName.new}).reason
		assert_equal 'Cannot generate an anonymous TestGenerate::OwnName. Only Hash, Array, String, Symbol, Integer, Float, true, false, nil, Time, and SOML::Duration can be generated', generate_error({'a' => Class.new(OwnName).new}).reason
		hash = {}.compare_by_identity
		hash[OwnName.new] = 1
		assert_equal 'A key must be a String or a Symbol, not a TestGenerate::OwnName, because a key is never converted', generate_error(hash).reason
		assert_equal 'A duration is a whole number of nanoseconds, got TestGenerate::OwnName', assert_raises(TypeError) { SOML::Duration.new(nanoseconds: OwnName.new) }.message
		assert_equal 'no implicit conversion of TestGenerate::OwnName into String', assert_raises(TypeError) { SOML.parse(OwnName.new) }.message
	end

	# The message of a `GenerateError` is often printed to a terminal, so a character that a terminal acts on, such as the escape of a class name, is replaced, as in a `ParseError`.
	def test_an_error_message_cannot_hold_a_terminal_escape
		type = Class.new
		type.set_temporary_name("\e[31mred\u202E")
		error = generate_error({"\e" => {'b' => type.new}})
		refute_match(/[\e\u202E]/, error.message)
		assert_equal "Cannot generate a \uFFFD[31mred\uFFFD. Only Hash, Array, String, Symbol, Integer, Float, true, false, nil, Time, and SOML::Duration can be generated", error.reason
		assert_equal "#{error.reason} (at \"\\u001b\".b)", error.message
	end

	# A `TypeError` names a value or a class from the caller too, and a string's `inspect` escapes a control character but not a bidirectional control.
	def test_a_type_error_message_cannot_hold_a_terminal_escape
		type = Class.new
		type.set_temporary_name("\e[31mred\u202E")
		messages = [
			assert_raises(TypeError) { SOML.parse(type.new) }.message,
			assert_raises(TypeError) { SOML::Duration.new(nanoseconds: 1) + type.new }.message,
			assert_raises(TypeError) { SOML::Duration.new(nanoseconds: "\u202Eabc") }.message,
			assert_raises(TypeError) { SOML::Duration.new(nanoseconds: :"\u202Ex") }.message
		]
		messages.each do |message|
			refute_match(/[\e\u202E]/, message)
		end
		assert_equal "A duration is a whole number of nanoseconds, got \"\uFFFDabc\"", messages[2]
	end

	class OwnInspectTime < Time
		def inspect = raise('not called')
	end

	def test_an_instant_error_shows_a_time_subclass_as_time_shows_it
		time = OwnInspectTime.at(Rational(1, 3)).utc
		assert_match(/\ACannot generate the instant 1970-01-01 00:00:00 1\/3 UTC, because it has a fraction/, generate_error({'a' => time}).reason)
	end

	# `raise error, 'Other'` copies the error, and the generator adds to the path of the error it rescues.
	def test_a_copy_of_an_error_has_its_own_path
		error = generate_error({'a' => [Float::NAN]})
		copy = error.exception('Other')
		copy.path << 9
		assert_equal ['a', 0], error.path
		assert_equal ['a', 0, 9], copy.path
		assert_equal 'Other (at a[0][9])', copy.message
	end

	# A key too deep for `inspect` to show is still a `GenerateError`. An identity hash does not hash the key, which is deep too.
	#
	# Inside `edit`, rescuing the `SystemStackError` of `inspect` was not enough: the stack is deeper there, and the overflow crashed the process with SIGILL instead. So a key that can nest is never inspected.
	def test_a_key_that_is_too_deep_to_inspect_is_refused
		deep = []
		1_000_000.times { deep = [deep] }

		hash = {}.compare_by_identity
		hash[deep] = 1
		assert_equal 'A key must be a String or a Symbol, not an Array, because a key is never converted', generate_error(hash).reason
		assert_equal 'A key must be a String or a Symbol, not an Array, because a key is never converted', assert_raises(SOML::GenerateError) { SOML.edit('a: 1', ['a'], hash) }.reason

		# A `Numeric` subclass shows its instance variables in `inspect`, so it can be as deep.
		hash = {}.compare_by_identity
		hash[Amount.new(deep)] = 1
		assert_equal 'A key must be a String or a Symbol, not a TestGenerate::Amount, because a key is never converted', generate_error(hash).reason
	end

	class Amount < Numeric
		def initialize(parts)
			super()
			@parts = parts
		end
	end

	# A deep hash as a key, a struct, and a number that is not an `Integer` or a `Float` are named by their class, and a huge integer is still shown.
	def test_a_key_that_is_not_a_string_or_a_symbol_is_named_by_its_class_unless_it_is_an_integer_or_a_float
		deep = {}
		300_000.times { deep = {'a' => deep} }

		# Pairs rather than a hash, which would hash the deep key.
		[
			[deep, 'not a Hash,'],
			[Point.new(1), 'not a TestGenerate::Point,'],
			[Rational(1, 2), 'not a Rational,'],
			[2**64, 'not an Integer (18446744073709551616),'],
			[-0.5, 'not a Float (-0.5),']
		].each do |key, expected|
			hash = {}.compare_by_identity
			hash[key] = 1
			assert_includes generate_error(hash).reason, expected
		end
	end

	# An anonymous subclass is named by the class that it comes from, in UTF-8 too.
	def test_an_anonymous_subclass_of_a_class_whose_name_is_not_utf8_is_named_in_utf8
		klass = eval("class TestGenerate::Bあ; self; end".encode(Encoding::Shift_JIS))
		error = generate_error({'é' => Class.new(klass).new})
		assert_equal "Cannot generate an anonymous TestGenerate::Bあ. Only Hash, Array, String, Symbol, Integer, Float, true, false, nil, Time, and SOML::Duration can be generated (at \"é\")", error.message
	end

	# A long path is cut short in the message, an escape included, and a long key in a reason is cut short too.
	def test_a_long_path_and_a_long_key_are_cut_short_in_the_message
		key = "x\u202E" * 30
		error = generate_error({'a' => [{key => [Float::NAN]}]})
		assert_equal ['a', 0, key, 0], error.path
		assert error.message.end_with?("(at a[0].\"#{'x\\u{202e}' * 20}…\"[0])"), error.message

		long = 'k' * 50
		assert_equal "Cannot generate the key #{'k' * 40}… twice, because two keys, such as :a and 'a', are the same string", generate_error({long => 1, long.to_sym => 2}).reason
	end

	# A number is shown, and a value that `describe` names already is not shown twice.
	def test_a_key_that_is_a_number_is_shown_and_one_that_is_named_is_not_repeated
		assert_equal 'A key must be a String or a Symbol, not a Float (1.5), because a key is never converted', generate_error({1.5 => 1}).reason
		assert_equal 'A key must be a String or a Symbol, not nil, because a key is never converted', generate_error({nil => 1}).reason
		assert_equal 'A key must be a String or a Symbol, not true, because a key is never converted', generate_error({true => 1}).reason
		assert_equal 'A key must be a String or a Symbol, not an Object, because a key is never converted', generate_error({Object.new => 1}).reason
	end

	# A class defined in a source file in another encoding, such as Shift_JIS, has its name in that encoding.
	def test_a_class_whose_name_is_not_utf8_is_named_in_utf8
		klass = eval("class TestGenerate::Aあ; self; end".encode(Encoding::Shift_JIS))
		error = generate_error({'café' => klass.new})
		assert_equal "Cannot generate a TestGenerate::Aあ. Only Hash, Array, String, Symbol, Integer, Float, true, false, nil, Time, and SOML::Duration can be generated (at \"café\")", error.message
		assert_equal Encoding::UTF_8, error.message.encoding

		hash = {}.compare_by_identity
		hash[klass.new] = 1
		assert_equal 'A key must be a String or a Symbol, not a TestGenerate::Aあ, because a key is never converted (at "café")', generate_error({'café' => hash}).message
		assert_equal "Cannot generate a TestGenerate::Aあ. Only Hash, Array, String, Symbol, Integer, Float, true, false, nil, Time, and SOML::Duration can be generated (at \"é\")", assert_raises(SOML::GenerateError) { SOML.edit("'é': 1", ['é'], klass.new) }.message

		# The `TypeError` of the other methods names it in UTF-8 too.
		[
			[-> { SOML.parse(klass.new) }, 'no implicit conversion of TestGenerate::Aあ into String'],
			[-> { SOML::Duration.new(nanoseconds: klass.new) }, 'A duration is a whole number of nanoseconds, got TestGenerate::Aあ'],
			[-> { SOML::Duration.new(nanoseconds: 1) + klass.new }, "TestGenerate::Aあ can't be coerced into SOML::Duration"]
		].each do |call, message|
			error = assert_raises(TypeError, &call)
			assert_equal message, error.message
			assert_equal Encoding::UTF_8, error.message.encoding
		end
	end

	def test_the_error_names_where_the_value_is
		error = generate_error({outer: {inner: Object.new}})
		assert_equal %w[outer inner], error.path
		assert error.message.end_with?(' (at outer.inner)'), error.message
		refute_includes error.reason, '(at'
	end

	def test_the_error_path_has_array_indexes_and_quotes_keys_that_are_not_bare
		error = generate_error({'servers' => [{'ratio' => 1.0}, {'a b' => Float::NAN}]})
		assert_equal ['servers', 1, 'a b'], error.path
		assert error.message.end_with?(' (at servers[1]."a b")'), error.message

		error = generate_error([[1, Float::NAN]])
		assert_equal [0, 1], error.path
		assert error.message.end_with?(' (at [0][1])'), error.message
	end

	# A key in the message is quoted, shortened, and escaped as in the errors of `parse` and `edit`, so that a key from untrusted data cannot reorder the text or run a terminal escape. The path keeps the keys as they are.
	def test_the_error_path_in_the_message_is_shortened_and_escaped
		error = generate_error({"x\u202Ey" => {"\e[2J" => Float::NAN}})
		assert_equal ["x\u202Ey", "\e[2J"], error.path
		assert error.message.end_with?(' (at "x\u{202e}y"."\u001b[2J")'), error.message

		key = 'k' * 50
		error = generate_error({key => Float::NAN})
		assert_equal [key], error.path
		assert error.message.end_with?(" (at #{'k' * 40}…)"), error.message

		# A key in the reason is shown the same way.
		assert_equal "Cannot generate the key \"x\\u{202e}\" twice, because two keys, such as :a and 'a', are the same string", generate_error({"x\u202E" => 1, "x\u202E": 2}).reason
		assert_equal 'Cannot generate the key "x\\ry\\u{202e}", because it contains a carriage return (U+000D), which is not representable', generate_error({"x\ry\u202E" => 1}).reason
	end

	# `raise error, 'other'` makes a copy with that message, as for any exception, and the copy keeps the path.
	def test_a_copy_of_the_error_with_another_message_keeps_the_path
		error = generate_error({'a' => Float::NAN}).exception('Other')
		assert_equal 'Other (at a)', error.message
		assert_equal 'Other', generate_error(1).exception('Other').message
	end

	def test_a_top_level_error_has_no_path
		error = generate_error(1)
		assert_empty error.path
		assert_equal error.reason, error.message
	end

	def test_the_generate_error_is_a_soml_error
		assert_kind_of SOML::Error, generate_error({'a' => Float::NAN})
		assert_kind_of StandardError, generate_error({'a' => Float::NAN})
	end

	# Conversion methods are not called, as `toJSON` is not in JS, so a value is written only for its class.
	def test_conversion_methods_are_not_called
		value = Object.new

		def value.to_str
			'x'
		end

		def value.to_h
			{'a' => 1}
		end

		def value.to_ary
			[1]
		end

		def value.to_time
			Time.at(0)
		end

		generate_error({'a' => value})
		generate_error(value)
		generate_error({'a' => Struct.new(:x).new(1)})
	end

	def test_an_object_that_only_claims_to_be_a_type_is_refused
		value = Object.new

		def value.is_a?(_type)
			true
		end

		def value.nanoseconds
			1
		end

		generate_error({'a' => value})
		generate_error(value)
	end

	def test_frozen_values
		assert_equal "a: [\n\t1\n]\n", SOML.generate({'a' => [1].freeze}.freeze)
		assert_equal "a: 'x'\n", SOML.generate(SOML.parse("a: 'x'", freeze: true))
	end

	def test_subclasses_of_hash_array_and_string_are_written_like_their_base_class
		hash_class = Class.new(Hash)
		array_class = Class.new(Array)
		string_class = Class.new(String)
		value = hash_class.new
		value['b'] = array_class.new([string_class.new('x')])
		value['a'] = 1
		assert_equal "b: [\n\t'x'\n]\na: 1\n", SOML.generate(value)
		assert_equal "a: 1\nb: [\n\t'x'\n]\n", SOML.generate(value, canonical: true)
	end

	# Top-level value

	def test_the_top_level_value_must_be_a_hash_or_an_array
		['x', :x, 1, 1.5, true, nil, Time.now, duration(1), Set[1], Object.new].each do |value|
			assert_match(/top-level value must be a Hash or an Array/, generate_error(value).message, value.inspect)
		end
	end

	def test_the_top_level_error_names_what_it_got
		assert_match(/a String\z/, generate_error('x').message)
		assert_match(/nil\z/, generate_error(nil).message)
		assert_match(/an Integer\z/, generate_error(1).message)
		assert_match(/a Set\z/, generate_error(Set[1]).message)
	end

	# Structure

	def test_a_circular_reference_is_refused
		object = {'a' => 1}
		object['self'] = object
		assert_match(/circular/, generate_error(object).message)

		array = []
		array << array
		assert_match(/circular/, generate_error(array).message)

		deep = {'a' => {'b' => {}}}
		deep['a']['b']['c'] = deep['a']
		error = generate_error(deep)
		assert_match(/circular/, error.message)
		assert_equal %w[a b c], error.path
	end

	def test_a_shared_reference_that_is_not_circular_is_written_twice
		shared = {'x' => 1}
		assert_equal "a: {\n\tx: 1\n}\nb: {\n\tx: 1\n}\nc: [\n\t{\n\t\tx: 1\n\t}\n\t{\n\t\tx: 1\n\t}\n]\n", SOML.generate({'a' => shared, 'b' => shared, 'c' => [shared, shared]})
	end

	def test_a_shared_empty_container_is_written_twice
		empty_array = []
		empty_hash = {}
		assert_equal "a: []\nb: []\nc: {}\nd: {}\n", SOML.generate({'a' => empty_array, 'b' => empty_array, 'c' => empty_hash, 'd' => empty_hash})
	end

	def test_a_failed_generation_does_not_poison_the_next_one
		object = {'a' => {}}
		object['a']['b'] = object
		generate_error(object)

		fine = {'a' => {}}
		assert_equal "x: {\n\ta: {}\n}\ny: {\n\ta: {}\n}\n", SOML.generate({'x' => fine, 'y' => fine})
		assert_equal "a: {\n\ta: 1\n}\n", SOML.generate({'a' => {'a' => 1}})
	end

	def test_100_levels_of_nesting_are_written
		assert SOML.generate(nested_arrays(100)).start_with?("[\n")
		assert SOML.generate(nested_hashes(100)).start_with?("a: {\n")
	end

	def test_more_than_100_levels_are_refused
		assert_match(/nested more than 100 levels/, generate_error(nested_arrays(101)).message)
		assert_match(/nested more than 100 levels/, generate_error(nested_hashes(101)).message)
		assert_match(/nested more than 100 levels/, generate_error([nested_hashes(100)]).message)
	end

	def test_the_top_level_object_counts_as_a_level
		value = nested_hashes(100)
		assert SOML.generate(value).start_with?("a: {\n")
		generate_error({'a' => value})
	end

	def test_the_nesting_limit_matches_the_parser
		[nested_arrays(100), nested_hashes(100)].each do |value|
			text = SOML.generate(value)
			assert_equal text, SOML.generate(SOML.parse(text))
		end
	end

	# Round trips, from `test/round-trip.ts`

	def test_every_single_scalar_value_survives_as_a_value_and_as_a_key
		characters = []
		code_point = 0

		while code_point <= 0x10FFFF
			characters << code_point.chr(Encoding::UTF_8) unless code_point == 0x0D || code_point.between?(0xD800, 0xDFFF)
			code_point += code_point < 0x30000 ? 1 : 0x101
		end

		# A batch of characters in one document is fast, and the characters of a batch that fails are checked one by one, so that the failure names them.
		survives = lambda do |batch|
			value = batch.to_h { [it, it] }
			SOML.parse(SOML.generate(value)) == value
		end

		failed_batches = characters.each_slice(1024).reject(&survives)
		assert_empty failed_batches.flatten.reject { survives.([it]) }.map { format('U+%04X', it.ord) }
		assert_empty failed_batches.map { format('U+%04X to U+%04X', it.first.ord, it.last.ord) }
	end

	def test_json_integers_are_ints_and_json_fractions_are_floats
		assert_same_value({'a' => 1, 'b' => 1.5, 'c' => [-0.5, 10]}, SOML.parse('{"a": 1, "b": 1.5, "c": [-0.5, 10]}'))
	end

	def test_every_float_survives_a_round_trip_bit_for_bit
		random = Random.new(42)
		specials = [0.0, 1.0, -1.0, 0.1, 0.5, 1.5, 1e21, 1e-7, 1e20, 1e-6, Float::MAX, 5e-324, -Float::MAX, Float::EPSILON, Float::MIN, Float::INFINITY, -Float::INFINITY, 2.0**53, Math::PI]

		values = specials + Array.new(5000) do
			# A random bit pattern, so every exponent and every subnormal is reachable.
			value = random.bytes(8).unpack1('G')
			value.nan? ? 0.0 : value
		end

		values.each do |value|
			text = SOML.generate({'a' => value})
			parsed = SOML.parse(text)['a']
			assert_equal [value].pack('G'), [parsed].pack('G'), "#{value} became #{text}"
		end
	end

	def test_every_int64_survives_a_round_trip
		random = Random.new(7)
		values = [-(2**63), (2**63) - 1, 0, -1, 2**53, (2**53) + 1, -(2**53) - 1] + Array.new(5000) { random.rand(2**64) - (2**63) }

		values.each do |value|
			assert_same_value value, SOML.parse(SOML.generate({'a' => value}))['a']
		end
	end

	def test_every_instant_survives_a_round_trip
		random = Random.new(9)
		minimum = -62_135_596_800 * 1_000_000_000
		maximum = (253_402_300_800 * 1_000_000_000) - 1

		Array.new(2000) { random.rand(minimum..maximum) }.each do |nanoseconds|
			value = Time.at(Rational(nanoseconds, 1_000_000_000), in: 'UTC')
			assert_same_value value, SOML.parse(SOML.generate({'a' => value}))['a']
		end
	end

	def test_every_duration_survives_a_round_trip
		random = Random.new(13)

		Array.new(2000) { random.rand(-(2**63)..((2**63) - 1)) >> random.rand(0..63) }.each do |nanoseconds|
			value = duration(nanoseconds)
			assert_same_value value, SOML.parse(SOML.generate({'a' => value}))['a']
		end
	end

	def test_every_string_survives_a_round_trip_as_a_value_and_as_a_key
		random = Random.new(11)
		characters = ['a', 'Z', '0', '_', '-', '.', ' ', "'", '"', '\\', "\n", "\t", "\u0000", "\u0001", "\u001F", "\u007F", "\u0080", "\u00A0", 'é', "\u2028", "\uD7FF", "\uE000", "\uFEFF", "\uFFFD", "\uFFFF", '😀', "\u{10000}", "\u{10FFFF}", '#', '/*', '*/', '/-', "'''", '"""', ':', ',', '{', ']']

		2000.times do
			value = Array.new(random.rand(0..20)) { characters.sample(random:) }.join
			parsed = SOML.parse(SOML.generate({value => value}))
			assert_equal [value], parsed.keys, value.inspect
			assert_equal value, parsed[value], value.inspect
		end
	end
end
