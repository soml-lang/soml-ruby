# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'

class TestAPI < Minitest::Test
	def test_parse_returns_a_hash_or_an_array
		assert_equal({'a' => 1}, SOML.parse('a: 1'))
		assert_equal [1, 2], SOML.parse('[1, 2]')
	end

	def test_parse_maps_every_type
		document = SOML.parse(<<~SOML)
			string: 'text'
			int: 3
			float: 3.0
			bool: true
			off: false
			null: null
			date: 2026-09-19
			instant: 2026-09-19T14:00:00.123456789+02:00
			duration: 1h30m
			array: [1, 'two']
			object: {a: 1}
		SOML

		assert_same_value(
			{
				'string' => 'text',
				'int' => 3,
				'float' => 3.0,
				'bool' => true,
				'off' => false,
				'null' => nil,
				'date' => Date.new(2026, 9, 19, Date::GREGORIAN),
				'instant' => Time.at(1_789_819_200, 123_456_789, :nsec, in: 'UTC'),
				'duration' => SOML::Duration.new(nanoseconds: 5_400_000_000_000),
				'array' => [1, 'two'],
				'object' => {'a' => 1}
			},
			document
		)
	end

	def test_an_instant_is_a_time_in_utc_exact_to_the_nanosecond
		time = SOML.parse('a: 9999-12-31T23:59:59.999999999Z')['a']
		assert_predicate time, :utc?
		assert_equal 999_999_999, time.nsec
		assert_equal 9999, time.year
		assert_equal Time.at(-62_135_596_800, in: 'UTC'), SOML.parse('a: 0001-01-01T00:00:00Z')['a']
	end

	def test_strings_and_keys_are_utf8
		document = SOML.parse("'é': 'ü'\nb: \"y\"".b)
		key, value = document.first
		assert_equal Encoding::UTF_8, key.encoding
		assert_equal Encoding::UTF_8, value.encoding
		assert_equal Encoding::UTF_8, document['b'].encoding
		assert(document.keys.all? { it.encoding == Encoding::UTF_8 })
		assert_equal({'é' => 'ü', 'b' => 'y'}, document)
	end

	def test_symbolize_names_still_finds_duplicate_keys
		error = parse_error("a: 1\n'a': 2", symbolize_names: true)
		assert_equal 'Duplicate key a', error.reason
	end

	def test_freeze_makes_the_result_deeply_frozen_and_shareable
		document = SOML.parse("a: 'x'\nb: [{c: 2026-09-19T14:00:00Z}, 'y']\nd: {e: 1s}", freeze: true)
		assert_predicate document, :frozen?
		assert_predicate document['a'], :frozen?
		assert_predicate document['b'], :frozen?
		assert_predicate document['b'][0], :frozen?
		assert_predicate document['b'][0]['c'], :frozen?
		assert_predicate document['b'][1], :frozen?
		assert_predicate document['d'], :frozen?
		assert document.keys.all?(&:frozen?)
		assert Ractor.shareable?(document)
	end

	def test_freeze_with_symbolize_names
		document = SOML.parse('a: [1]', symbolize_names: true, freeze: true)
		assert_equal({a: [1]}, document)
		assert Ractor.shareable?(document)
	end

	def test_parse_does_not_change_its_input
		source = "a: 'é'".b
		SOML.parse(source)
		assert_equal Encoding::BINARY, source.encoding
	end

	def test_parse_accepts_a_frozen_string
		assert_equal({'a' => 1}, SOML.parse('a: 1'.freeze))
	end

	def test_invalid_utf8_is_reported_with_its_position
		error = parse_error("a: 1\nb: 'x\xFFy'".b)
		assert_equal ['Invalid UTF-8 byte 0xFF', 2, 6, 10], [error.reason, error.line, error.column, error.offset]
	end

	def test_a_utf8_sequence_cut_short_at_the_end
		error = parse_error("a: '\xF0\x9F\x98".b)
		assert_equal ['Incomplete UTF-8 sequence at the end of the input', 1, 5], [error.reason, error.line, error.column]
	end

	def test_an_impossible_lead_byte_at_the_end_is_invalid_rather_than_cut_short
		error = parse_error("a: '\xF8".b)
		assert_equal 'Invalid UTF-8 byte 0xF8', error.reason

		error = parse_error("a: '\xE0\x80".b)
		assert_equal 'Invalid UTF-8 byte 0xE0', error.reason
	end

	def test_load_file
		Dir.mktmpdir do |directory|
			path = File.join(directory, 'config.soml')
			File.binwrite(path, "name: 'é'\nport: 8080\n")
			assert_same_value({'name' => 'é', 'port' => 8080}, SOML.load_file(path))
			assert_equal({name: 'é', port: 8080}, SOML.load_file(path, symbolize_names: true))
			assert Ractor.shareable?(SOML.load_file(path, freeze: true))
		end
	end

	def test_load_file_reads_in_binary_mode_so_a_carriage_return_is_refused
		Dir.mktmpdir do |directory|
			path = File.join(directory, 'config.soml')
			File.binwrite(path, "a: 1\r\nb: 2\r\n")
			error = assert_raises(SOML::ParseError) { SOML.load_file(path) }
			assert_equal 'A carriage return (U+000D) is not allowed anywhere. Use LF line endings', error.reason
		end
	end

	def test_an_error_from_load_file_names_the_file
		Dir.mktmpdir do |directory|
			path = File.join(directory, 'config.soml')
			File.binwrite(path, "a: 1\nb: nope\n")
			error = assert_raises(SOML::ParseError) { SOML.load_file(path) }
			assert_equal path, error.path
			assert_equal "Unexpected “nope”. A string value must be quoted, as in 'nope' at #{path}:2:4", error.message
			assert_equal 'Unexpected “nope”. A string value must be quoted, as in \'nope\'', error.reason
			assert_equal [2, 4], [error.line, error.column]
		end
	end

	def test_an_error_from_load_file_names_the_file_of_a_path_object
		Dir.mktmpdir do |directory|
			path = File.join(directory, 'config.soml')
			File.binwrite(path, "a: 1\na: 2\n")

			File.open(path) do |file|
				error = assert_raises(SOML::ParseError) { SOML.load_file(file) }
				assert_equal path, error.path
				assert_equal "Duplicate key a at #{path}:2:1", error.message
			end
		end
	end

	# A binary path, such as one from `ARGV` with `LANG=C`, joins a reason that is not ASCII.
	def test_an_error_from_load_file_names_a_file_whose_path_is_binary
		Dir.mktmpdir do |directory|
			path = File.join(directory, 'café.soml')
			File.binwrite(path, "a: é\n")
			# Linux opens the bytes of a path as they are, so the Latin-1 path names another file there, while macOS converts it to UTF-8, which names the same file.
			File.binwrite(path.encode(Encoding::ISO_8859_1), "a: é\n")

			[path.b, Pathname(path.b), path.encode(Encoding::ISO_8859_1)].each do |given|
				error = assert_raises(SOML::ParseError) { SOML.load_file(given) }
				assert_equal "Expected a value, but found “é” at #{path}:1:4", error.message
				assert_equal Encoding::UTF_8, error.message.encoding
				assert_equal File.path(given), error.path
			end

			# An encoding that has no converter to UTF-8 is read as UTF-8, as a binary path is.
			given = path.b.force_encoding(Encoding::Windows_1258)
			error = assert_raises(SOML::ParseError) { SOML.load_file(given) }
			assert_equal "Expected a value, but found “é” at #{path}:1:4", error.message
			assert_equal given, error.path

			File.binwrite(path, "a: #{'x' * 50}\n")
			assert_equal "Unexpected “#{'x' * 40}…”. A string value must be quoted, as in '#{'x' * 40}…' at #{path}:1:4", assert_raises(SOML::ParseError) { SOML.load_file(path.b) }.message
		end
	end

	# The path is shown as the source is, so that printing the message cannot run a terminal escape.
	def test_an_error_from_load_file_replaces_the_control_characters_of_the_path
		Dir.mktmpdir do |directory|
			path = File.join(directory, "x\e[2J\u202E.soml")
			File.binwrite(path, "a: 1\na: 2\n")
			error = assert_raises(SOML::ParseError) { SOML.load_file(path) }
			assert_equal "Duplicate key a at #{directory}/x\uFFFD[2J\uFFFD.soml:2:1", error.message
			assert_equal path, error.path
		end
	end

	def test_an_error_from_load_file_replaces_a_line_break_in_the_path_and_keeps_a_tab
		Dir.mktmpdir do |directory|
			path = File.join(directory, "a\nb\tc.soml")
			File.binwrite(path, "a: nope\n")
			error = assert_raises(SOML::ParseError) { SOML.load_file(path) }
			assert_equal "Unexpected “nope”. A string value must be quoted, as in 'nope' at #{directory}/a\uFFFDb\tc.soml:1:4", error.message
			# The message stays on one line, before the code frame.
			assert_equal "#{error.message} (SOML::ParseError)\n", error.detailed_message.lines.first
			assert_equal path, error.path
		end
	end

	def test_an_error_from_parse_has_no_path
		assert_nil parse_error('a: nope').path
	end

	def test_load_file_raises_for_a_missing_file
		assert_raises(Errno::ENOENT) { SOML.load_file(File.join(__dir__, 'missing.soml')) }
	end

	def test_generate_returns_a_utf8_string
		text = SOML.generate({'é' => 'ü'})
		assert_equal Encoding::UTF_8, text.encoding
		assert_equal "'é': 'ü'\n", text
	end

	def test_parse_works_inside_a_ractor
		previous = Warning[:experimental]
		Warning[:experimental] = false

		ractor = Ractor.new do
			# A radix int, an escaped string, and an error read the constant tables that a ractor may only read when they are shareable.
			error = begin
				SOML.parse('a: 0xZZ')
			rescue SOML::ParseError => parse_error
				parse_error.reason
			end

			[SOML.parse("a: 1.5s\nb: [2026-09-19T14:00:00Z, 0x1F, 0o7, 0b1, \"x\\ty\"]", freeze: true), SOML.generate({'a' => [1, 2.5, "x\ty"]}), error]
		end

		document, text, error = ractor.value
		assert_equal SOML::Duration.new(nanoseconds: 1_500_000_000), document['a']
		assert_equal [31, 7, 1, "x\ty"], document['b'].drop(1)
		assert_equal "a: [\n\t1\n\t2.5\n\t\"x\\ty\"\n]\n", text
		assert_equal 'Invalid hexadecimal digit “Z”', error
	ensure
		Warning[:experimental] = previous
	end

	def test_the_version
		assert_match(/\A\d+\.\d+\.\d+\z/, SOML::VERSION)
	end

	# `Module#constants` leaves out private constants, so the names are read from the source too. `const_get` reads a private constant.
	def test_every_constant_is_shareable
		names = Dir[File.join(__dir__, '../lib/**/*.rb')].flat_map { File.read(it).scan(/^\t+([A-Z][A-Za-z0-9_]*) = /).flatten.map(&:to_sym) }
		checked = []

		[SOML, SOML::Parser, SOML::Generator, SOML::ParseError, SOML::Duration, SOML::Tree, SOML::Printer, SOML::Editor].each do |owner|
			(owner.constants(false) | names).select { owner.const_defined?(it, false) }.each do |name|
				assert Ractor.shareable?(owner.const_get(name)), "#{owner}::#{name}"
				checked << name
			end
		end

		assert_empty names - checked, 'A constant in a class that this test does not check'
	end

	def test_a_generate_error_has_the_path_in_every_string_form
		error = generate_error({'servers' => [{'ratio' => Float::NAN}]})
		assert_equal 'NaN is not representable. Use nil for a missing value (at servers[0].ratio)', error.message
		assert_equal error.message, error.to_s
		assert_equal error.message, "#{error}"
		assert_includes error.inspect, '(at servers[0].ratio)'
	end

	def test_a_basic_object_is_refused_with_a_generate_error
		assert_match(/\ACannot generate a BasicObject\./, generate_error({'a' => BasicObject.new}).reason)
		# Only a hash that compares by identity can hold one as a key, because it has no `hash` method.
		hash = {}.compare_by_identity
		hash[BasicObject.new] = 1
		assert_match(/\AA key must be a String or a Symbol, not a BasicObject/, generate_error(hash).reason)
	end

	def test_an_invalid_key_has_the_path_of_its_object
		assert_equal ['a'], generate_error({'a' => {"x\ry" => 1}}).path
		assert_equal ['a'], generate_error({'a' => {(+"x\xFF").force_encoding(Encoding::UTF_8) => 1}}).path
		assert_equal ['a'], generate_error({'a' => {1 => 1}}).path
		assert_equal [], generate_error({"x\ry" => 1}).path
		assert_equal 'Cannot generate the key "x\ry", because it contains a carriage return (U+000D), which is not representable', generate_error({"x\ry" => 1}).reason
	end

	def test_two_string_keys_that_are_the_same_string
		error = generate_error({'é' => 1, 'é'.encode(Encoding::ISO_8859_1) => 2})
		assert_equal "Cannot generate the key \"é\" twice, because two keys, such as :a and 'a', are the same string", error.reason
	end

	# A US-ASCII string may hold the bytes of a UTF-8 name, so two keys in US-ASCII and UTF-8 can be the same name without being the same key.
	def test_two_string_keys_that_are_the_same_name_in_us_ascii_and_utf8
		hash = {'é' => 1, (+'é').force_encoding(Encoding::US_ASCII) => 2}
		assert_raises(SOML::GenerateError) { SOML.generate(hash) }
		assert_raises(SOML::GenerateError) { SOML.generate(hash, canonical: true) }
	end

	def test_a_us_ascii_string_with_other_bytes_is_read_as_utf8_in_both_directions
		value = (+'é').force_encoding(Encoding::US_ASCII)
		assert_equal({'a' => 'é'}, SOML.parse("a: '#{'é'}'".dup.force_encoding(Encoding::US_ASCII)))
		assert_equal "a: 'é'\n", SOML.generate({'a' => value})
		assert_equal "'é': 1\n", SOML.generate({value => 1})
	end

	def test_a_parse_error_does_not_change_when_the_source_does
		source = +"a: 1\nb: x"
		error = parse_error(source)
		source.replace("\xFF\xFE")
		assert_equal "  1 | a: 1\n> 2 | b: x\n    |    ^", error.code_frame
	end

	# `Symbol#<=>` compares the bytes of each symbol in its own encoding, which is not the order of the UTF-8 names.
	def test_symbol_keys_in_another_encoding_are_sorted_by_their_utf8_names
		latin = 'é'.encode(Encoding::ISO_8859_1).to_sym
		assert_equal "'é': 1\n'ÿ': 2\n", SOML.generate({'ÿ': 2, latin => 1}, canonical: true)
		assert_equal "Cannot generate the key \"é\" twice, because two keys, such as :a and 'a', are the same string", generate_error({latin => 1, 'ê': 2, 'é': 3}).reason
	end

	def test_a_key_error_names_the_key
		assert_equal 'A key must be a String or a Symbol, not an Integer (1), because a key is never converted', generate_error({'a' => {1 => 2}}).reason
	end

	def test_bare_key_is_a_boolean_for_any_string
		assert_same true, SOML.bare_key?('content-type')
		assert_same false, SOML.bare_key?('')
		assert_same false, SOML.bare_key?('a.b')
		assert_same false, SOML.bare_key?((+"\xFF").force_encoding(Encoding::UTF_8))
		assert_same false, SOML.bare_key?('é'.encode(Encoding::UTF_16LE))
	end

	def test_bare_key_is_a_boolean_for_any_symbol
		assert_same true, SOML.bare_key?(:'content-type')
		assert_same false, SOML.bare_key?(:'')
		assert_same false, SOML.bare_key?(:'a.b')
		assert_same false, SOML.bare_key?(:é)
	end

	# A key in an encoding that is not compatible with ASCII is read as the UTF-8 string it converts to, as `generate` reads it, so the two agree on which keys are bare.
	def test_bare_key_agrees_with_generate_for_a_key_in_another_encoding
		[['abc', Encoding::UTF_16LE], ['a-B_9', Encoding::UTF_32BE], ['a b', Encoding::UTF_16BE], ['é', Encoding::UTF_16LE], ['', Encoding::UTF_16LE]].each do |text, encoding|
			key = text.encode(encoding)
			assert_same SOML.generate({key => 1}).start_with?("#{text}: "), SOML.bare_key?(key), key.inspect
		end

		assert_same true, SOML.bare_key?('abc'.encode(Encoding::UTF_16LE))
		assert_same true, SOML.bare_key?('abc'.encode(Encoding::UTF_16LE).to_sym)
		assert_same false, SOML.bare_key?("\xD8\x00".b.force_encoding(Encoding::UTF_16BE))
	end

	def test_bare_key_of_an_empty_or_non_ascii_key_in_another_encoding_is_false
		assert_same false, SOML.bare_key?(''.encode(Encoding::UTF_16LE))
		assert_same false, SOML.bare_key?('aé'.encode(Encoding::UTF_32LE))
		assert_same true, SOML.bare_key?('404'.encode(Encoding::UTF_32LE))
	end

	# A value that is not a key at all, such as a number or nil, is a `false` answer, because it could never be a bare key. It is not an error: the method answers for every value, as `generate` needs it to decide whether to quote a key.
	def test_bare_key_is_false_for_a_non_key
		assert_same false, SOML.bare_key?(nil)
		assert_same false, SOML.bare_key?(5)
		assert_same false, SOML.bare_key?(true)
		assert_same false, SOML.bare_key?([])
		assert_same false, SOML.bare_key?({})
		assert_same false, SOML.bare_key?(Object.new)
	end

	def test_a_time_with_a_float_fraction_gets_a_hint
		# A Float is a binary fraction, so 0.5 is exact, while 0.1 is finer than a nanosecond.
		assert_equal "a: 1970-01-01T00:00:00.5Z\n", SOML.generate({'a' => Time.at(0.5)})
		assert_match(/Round it to nanoseconds with time.round\(9\)\z/, generate_error({'a' => Time.at(0.1)}).reason)
		assert_equal "a: 1970-01-01T00:00:00.1Z\n", SOML.generate({'a' => Time.at(0.1).round(9)})
	end
end
