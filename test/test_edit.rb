# frozen_string_literal: true

# Tests for `SOML.edit`, ported from soml-js's `test/edit.ts`, and property tests in the style of `test_properties.rb`.
#
# A JS `bigint` is an `Integer` here and a JS `number` a `Float`, and a JS `undefined` value is `delete: true`. The JS tests of the `integers` option and of `__proto__` do not apply to Ruby.

require_relative 'test_helper'
require_relative 'test_properties'

class TestEdit < Minitest::Test
	ROOT = File.join(__dir__, 'conformance')
	VALID_CASES = Dir.glob('valid/**/*.soml', base: ROOT).reject { it.end_with?('.canonical.soml', '.formatted.soml') }.sort
	SEED = TestProperties::SEED
	EXAMPLES = TestProperties::EXAMPLES

	def assert_edit(text, path, expected, value = nil, delete: false)
		actual = delete ? SOML.edit(text, path, delete: true) : SOML.edit(text, path, value)
		assert_equal expected, actual
	end

	def assert_edit_error(error_class, message, text, path, *value, **options)
		error = assert_raises(error_class) { SOML.edit(text, path, *value, **options) }
		assert_equal message, error.message if message
		error
	end

	# The paths of the API.

	def test_takes_symbols_and_strings_as_keys
		assert_equal "a: {\n\tb: 2\n}", SOML.edit("a: {\n\tb: 1\n}", [:a, :b], 2)
		assert_equal "a: 1\nb: 2", SOML.edit('a: 1', [:b], 2)
	end

	def test_a_new_value_is_written_as_generate_writes_it
		assert_equal "a: 2026-09-19T14:00:00.5Z\nb: 1h30m\nc: 'x'\nd: null", SOML.edit("a: 2026-09-19T14:00:00.5Z\nb: 1h30m\nc: 'x'\nd: 1", ['d'], nil)
		assert_equal "a: 2026-09-19T12:00:00Z\n", SOML.edit("a: 1\n", ['a'], Time.new(2026, 9, 19, 14, 0, 0, '+02:00'))
		assert_equal "a: 1h30m\n", SOML.edit("a: 1\n", ['a'], SOML::Duration.parse('90m'))
		assert_equal "a: 'b'\n", SOML.edit("a: 1\n", ['a'], :b)
		assert_equal "a: {\n\tc: 2\n\tb: 1\n}\n", SOML.edit("a: 1\n", ['a'], {c: 2, b: 1})
	end

	def test_a_key_is_quoted_as_generate_quotes_it
		assert_equal "x: 1\n\"a\\nb\": 1\n", SOML.edit("x: 1\n", ["a\nb"], 1)
		assert_equal "x: 1\n'é': 1\n", SOML.edit("x: 1\n", ['é'.encode(Encoding::ISO_8859_1)], 1)
	end

	def test_reads_the_source_as_parse_reads_it
		assert_equal "a: 'é'", SOML.edit("a: 1".b, ['a'], 'é')
		edited = SOML.edit("a: 'é'".encode(Encoding::UTF_16LE), ['b'], 1)
		assert_equal "a: 'é'\nb: 1", edited
		assert_equal Encoding::UTF_8, edited.encoding
	end

	def test_does_not_change_the_source_or_the_path
		source = +'a: 1'
		path = ['a']
		SOML.edit(source, path, 2)
		assert_equal 'a: 1', source
		assert_equal ['a'], path
	end

	def test_a_value_and_delete_cannot_be_given_together_or_both_left_out
		assert_edit_error(ArgumentError, 'Pass either a value or delete: true, not both', 'a: 1', ['a'], 2, delete: true)
		assert_edit_error(ArgumentError, 'Pass the new value, or delete: true to remove the value', 'a: 1', ['a'])
		assert_edit_error(ArgumentError, 'Pass the new value, or delete: true to remove the value', 'a: 1', ['a'], delete: false)
		assert_equal 'a: null', SOML.edit('a: 1', ['a'], nil)
	end

	def test_the_path_is_checked
		[[], 'a', nil, {'a' => 1}, [-1], [1.5], [nil], [Object.new], ['b', nil, 'c'], [true]].each do |path|
			assert_edit_error(TypeError, 'The path must be a non-empty array of keys and array indexes, or a member or value node from SOML.parse_tree', 'a: 1', path, 1)
			assert_edit_error(TypeError, 'The path must be a non-empty array of keys and array indexes, or a member or value node from SOML.parse_tree', 'a: 1', path, delete: true)
		end
	end

	def test_the_source_is_checked
		assert_raises(TypeError) { SOML.edit(1, ['a'], 1) }
		assert_raises(TypeError) { SOML.edit(BasicObject.new, ['a'], 1) }
		expected = parse_error('a: b')
		error = assert_edit_error(SOML::ParseError, nil, 'a: b', ['a'], 1)
		assert_equal [expected.reason, expected.line, expected.column], [error.reason, error.line, error.column]
	end

	def test_a_value_or_key_that_generate_refuses_raises_its_generate_error
		error = assert_edit_error(SOML::GenerateError, 'NaN is not representable. Use nil for a missing value (at a)', 'a: 1', ['a'], Float::NAN)
		assert_equal ['a'], error.path

		error = assert_edit_error(SOML::GenerateError, nil, "x: [\n\t1\n]", [:x, 1, :b], {c: [Float::NAN]})
		assert_equal ['x', 1, 'b', 'c', 0], error.path

		assert_edit_error(SOML::GenerateError, nil, 'a: 1', ['a'], -> { 1 })
		assert_edit_error(SOML::GenerateError, nil, 'a: 1', ['a'], 2**64)
		assert_edit_error(SOML::GenerateError, nil, 'a: 1', ["b\rc"], 1)
		assert_edit_error(SOML::GenerateError, nil, 'a: 1', ["b\xFF".b.force_encoding(Encoding::UTF_8)], delete: true)
	end

	# A key of the path that `generate` refuses is reported at the place of the object that holds it, as `generate` reports a key, and not at the top level.
	def test_a_key_of_the_path_that_generate_refuses_is_reported_where_it_is
		error = assert_edit_error(SOML::GenerateError, 'Cannot generate a key that is not valid UTF-8 (at a)', "a: {b: 1}\n", ['a', "\xFF".b], 1)
		assert_equal ['a'], error.path

		error = assert_edit_error(SOML::GenerateError, 'Cannot generate the key "b\\rc", because it contains a carriage return (U+000D), which is not representable (at x[0])', 'x: [{}]', [:x, 0, "b\rc"], 1)
		assert_equal ['x', 0], error.path

		error = assert_edit_error(SOML::GenerateError, nil, 'a: 1', ["b\rc"], 1)
		assert_equal [], error.path
	end

	# The keys of the path before the one that is refused are in its path as the strings they name, and a refused first key is at the top level.
	def test_a_refused_key_of_the_path_is_reported_after_the_keys_and_indexes_before_it
		error = assert_edit_error(SOML::GenerateError, 'Cannot generate a key that is not valid UTF-8 (at a[0])', 'a: [{}]', [:a, 0, "\xFF".b], 1)
		assert_equal ['a', 0], error.path

		error = assert_edit_error(SOML::GenerateError, 'Cannot generate the key "x\\ry", because it contains a carriage return (U+000D), which is not representable (at ok)', 'a: 1', ['ok', :"x\ry"], 1)
		assert_equal ['ok'], error.path

		error = assert_edit_error(SOML::GenerateError, 'Cannot generate a key that is not valid UTF-8', 'a: 1', ["\xFF".b, 'b'], 1)
		assert_equal [], error.path
	end

	def test_an_index_past_the_end_of_any_size_raises_an_index_error
		assert_edit_error(IndexError, 'Cannot edit a[18446744073709551616], because the array at a has 1 item. Add an item at index 1', 'a: [1]', ['a', 2**64], 1)
		assert_edit_error(IndexError, 'Cannot edit [5], because the document has 2 items. Add an item at index 2', '[1, 2]', [5], 3)
	end

	# A `GenerateError` for the new value shows the same path, so it is shortened and escaped the same way.
	def test_the_path_in_a_generate_error_is_shortened_and_escaped_as_in_the_other_errors
		assert_edit_error(SOML::GenerateError, 'NaN is not representable. Use nil for a missing value (at a."x\u{202e}y\u{2028}")', 'a: {}', ['a', "x\u202Ey\u2028"], Float::NAN)
		assert_edit_error(SOML::GenerateError, "NaN is not representable. Use nil for a missing value (at a.\"#{'k' * 40}…\")", 'a: {}', ['a', "#{'k' * 50}\n"], Float::NAN)
	end

	def test_a_long_key_is_shortened_in_a_message
		key = "#{'k' * 50}\n"
		assert_edit_error(TypeError, "Cannot edit a.\"#{'k' * 40}…\", because a is not an object or an array", 'a: 1', ['a', key], 1)
	end

	# The path comes from the caller, perhaps from user input, so a character that is invisible or that a terminal acts on is shown as an escape.
	def test_an_invisible_character_in_a_path_is_escaped_in_a_message
		assert_edit_error(TypeError, 'Cannot edit a."\u{7f}\n", because a is not an object or an array', 'a: 1', ['a', "\u007F\n"], 2)
		assert_edit_error(TypeError, 'Cannot edit a."x\u{202e}y\u{2028}", because a is not an object or an array', 'a: 1', ['a', "x‮y "], 2)
	end

	def test_format_and_edit_work_inside_a_ractor
		previous = Warning[:experimental]
		Warning[:experimental] = false

		ractor = Ractor.new do
			[SOML.format("a: [1,\n\"x\"] # c\nb: '''\n  y\n  '''"), SOML.edit("a: [1]\nb: {c: 1 /* c */}", ['b', 'd'], {'e' => [1.5]}), SOML.edit("a: [1, 2]", ['a', 0], delete: true)]
		end

		formatted, edited, removed = ractor.value
		assert_equal "a: [\n\t1\n\t\"x\"\n] # c\nb:\n\t'''\n\ty\n\t'''\n", formatted
		assert_equal "a: [1]\nb: {c: 1 /* c */, d: {e: [1.5]}}", edited
		assert_equal 'a: [2]', removed
	ensure
		Warning[:experimental] = previous
	end

	def test_a_removed_line_after_a_line_that_ends_with_a_non_ascii_character
		assert_equal "# é\nb: 2\n", SOML.edit("# é\na: 1\nb: 2\n", ['a'], delete: true)
		assert_equal "{\n\t# ✓\n}", SOML.edit("{\n\t# ✓\n\ta: 1\n}", ['a'], delete: true)
		assert_equal "[\n\t# 😀\n]", SOML.edit("[\n\t# 😀\n\t1\n]", [0], delete: true)
		assert_equal "a: 'é'\n\nc: 3\n", SOML.edit("a: 'é'\n\nb: 2\n\nc: 3\n", ['b'], delete: true)
	end

	def test_the_result_is_parsed
		# Every edit here is valid, so this only shows that the check accepts the result.
		assert_equal "a: [\n\t1\n\t2\n]\n", SOML.edit("a: [\n\t1\n]\n", ['a', 1], 2)
	end

	# Ported from the JS tests of errors.

	def test_a_path_through_a_value_that_is_not_a_container_raises_a_type_error
		assert_edit_error(TypeError, 'Cannot edit a.b, because a is not an object or an array', 'a: 1', ['a', 'b'], 1)
		assert_edit_error(TypeError, 'Cannot edit a.b, because a is an array, so it needs an index, not a key', 'a: [1]', ['a', 'b'], 1)
		assert_edit_error(TypeError, 'Cannot edit a[0], because a is an object, so it needs a key, not an index', 'a: {}', ['a', 0], 1)
		assert_edit_error(TypeError, 'Cannot edit a, because the document is an array, so it needs an index, not a key', '[1]', ['a'], 1)
		assert_edit_error(TypeError, 'Cannot edit a.b[0].x, because a.b is an object, so it needs a key, not an index', 'a: {b: {c: 1}}', ['a', 'b', 0, 'x'], delete: true)
		# A key with a dot is quoted, so that it is not read as two keys.
		assert_edit_error(TypeError, 'Cannot edit "a.b".c, because "a.b" is not an object or an array', "'a.b': 1", ['a.b', 'c'], 1)
	end

	def test_an_index_past_the_end_raises_an_index_error_for_a_new_value
		assert_edit_error(IndexError, 'Cannot edit a[3], because the array at a has 1 item. Add an item at index 1', 'a: [1]', ['a', 3], 1)
		assert_edit_error(IndexError, 'Cannot edit b[0], because b does not exist, so it has no index 0', 'a: 1', ['b', 0], 1)
	end

	# Removing a value that does not exist changes nothing and is not an error, so the result is the same string as the source.
	def test_removing_a_value_that_does_not_exist_changes_nothing
		[
			["a: 1\n", ['b']],
			["a: 1\n", ['b', 'c']],
			["a: 1\n", ['b', 0]],
			["a: {}\n", ['a', 'b', 0, 'c']],
			["a: {b: 1}\n", ['a', 'c']],
			["a: [1, 2]\n", ['a', 2]],
			["a: [1, 2]\n", ['a', 5]],
			["a: [1, 2]\n", ['a', 5, 'x']],
			["a: [1, 2]\n", ['a', 5, 0]],
			["a: []\n", ['a', 0]],
			["a: [1]\n", ['a', 2**64]],
			['[1, 2]', [5]],
			# No document has a key with a carriage return, so removing one finds nothing.
			["x: [{}]\n", [:x, 0, "b\rc"]],
			["x: {}\n", ['x', "b\rc"]],
			["x: {}\n", ['x', "b\rc", 0]],
			["a: 1\n", ["b\rc", 'd']]
		].each do |text, path|
			assert_edit(text, path, text, delete: true)
		end
	end

	def test_removing_the_same_path_twice_is_safe
		removed = SOML.edit("a: [1, 2]\nb: 3\n", ['a', 1], delete: true)
		assert_equal "a: [1]\nb: 3\n", removed
		assert_equal removed, SOML.edit(removed, ['a', 1], delete: true)

		removed = SOML.edit("a: 1\nb: 2\n", ['b'], delete: true)
		assert_equal "a: 1\n", removed
		assert_equal removed, SOML.edit(removed, ['b'], delete: true)
	end

	# The documented check of whether something was removed compares the bytes, because a binary source with a character that is not ASCII is not `==` to the UTF-8 result.
	def test_the_result_has_the_bytes_of_a_binary_source_when_nothing_was_removed
		source = "a: 'é'\nb: 1\n".b
		assert_equal source, SOML.edit(source, ['c'], delete: true).b
		refute_equal source, SOML.edit(source, ['b'], delete: true).b
	end

	# A removal raises the same errors as a new value when its path reaches a value of the wrong kind before it reaches nothing.
	def test_a_removal_whose_path_does_not_fit_the_document_raises
		assert_edit_error(TypeError, 'Cannot edit a.x, because a is not an object or an array', "a: 1\n", ['a', 'x'], delete: true)
		assert_edit_error(TypeError, 'Cannot edit a.x, because a is an array, so it needs an index, not a key', "a: [1]\n", ['a', 'x'], delete: true)
		assert_edit_error(TypeError, 'Cannot edit a[0], because a is an object, so it needs a key, not an index', "a: {b: 1}\n", ['a', 0], delete: true)
		assert_edit_error(TypeError, 'Cannot edit a[0].x, because a[0] is not an object or an array', "a: [1]\n", ['a', 0, 'x'], delete: true)
		assert_edit_error(TypeError, 'Cannot edit a."b\\rc", because a is not an object or an array', "a: 1\n", ['a', "b\rc"], delete: true)
		assert_edit_error(TypeError, 'Cannot edit a."b\\rc", because a is an array, so it needs an index, not a key', "a: [1]\n", ['a', "b\rc"], delete: true)
	end

	# The messages are the ones that JS `edit()` gives for the same edits, as JS writes them, where JS raises a `TypeError` for a `TypeError` here and a `RangeError` for an `IndexError` here.
	def test_the_messages_are_the_js_messages
		[
			[TypeError, 'Cannot edit a.b, because a is not an object or an array', "a: 1\n", ['a', 'b']],
			[TypeError, 'Cannot edit "a b".c, because "a b" is not an object or an array', "\"a b\": 1\n", ['a b', 'c']],
			[TypeError, 'Cannot edit a.b, because a is an array, so it needs an index, not a key', "a: [1]\n", ['a', 'b']],
			[TypeError, 'Cannot edit a[0], because a is an object, so it needs a key, not an index', "a: {b: 1}\n", ['a', 0]],
			[IndexError, 'Cannot edit a[5], because the array at a has 1 item. Add an item at index 1', "a: [1]\n", ['a', 5]],
			[IndexError, 'Cannot edit a[5], because the array at a has 0 items. Add an item at index 0', "a: []\n", ['a', 5]],
			[IndexError, 'Cannot edit [5], because the document has 2 items. Add an item at index 2', '[1, 2]', [5]],
			[IndexError, 'Cannot edit [5], because the document has 1 item. Add an item at index 1', '[1]', [5]],
			[IndexError, 'Cannot edit b[0].c[1], because b[0].c does not exist, so it has no index 1', "b: [{}]\n", ['b', 0, 'c', 1]],
			[IndexError, 'Cannot edit b[0][1], because b[0] does not exist, so it has no index 1', "b: []\n", ['b', 0, 1]],
			[IndexError, 'Cannot edit b[0], because b does not exist, so it has no index 0', "a: 1\n", ['b', 0]],
			[TypeError, 'The path must be a non-empty array of keys and array indexes, or a member or value node from SOML.parse_tree', "a: 1\n", []],
			[TypeError, 'The path must be a non-empty array of keys and array indexes, or a member or value node from SOML.parse_tree', "a: 1\n", ['a', -1]]
		].each do |error_class, message, text, path|
			assert_edit_error(error_class, message, text, path, 1)
		end
	end

	def test_the_nesting_limit_counts_from_where_the_value_goes
		deep = "#{'a: {' * 98}a: 1#{'}' * 98}"
		assert_equal "#{'a: {' * 98}a: {}#{'}' * 98}", SOML.edit(deep, ['a'] * 99, {})
		error = assert_edit_error(SOML::GenerateError, nil, deep, ['a'] * 99, {'b' => {}})
		assert_match(/nested more than 100 levels deep/, error.message)
		assert_equal [*(['a'] * 99), 'b'], error.path
	end

	# The examples in the readme.
	def test_the_examples_in_the_readme
		assert_edit("name: 'api' # The service\nport: 8080\n", ['port'], "name: 'api' # The service\nport: 9090\n", 9090)
		assert_edit("postgres: {\n\thost: 'db'\n}\n", ['postgres', 'port'], "postgres: {\n\thost: 'db'\n\tport: 5432\n}\n", 5432)
		assert_edit("a: 1\nb: 2\n", ['a'], "b: 2\n", delete: true)
	end

	# A replaced value is written in canonical form, and the rest keeps its spelling.
	def test_a_replaced_value_is_written_in_canonical_form_and_the_rest_keeps_its_spelling
		assert_edit("a: 0xFF\nb: 0b11 # Bits\n", ['a'], "a: 255\nb: 0b11 # Bits\n", 255)
		assert_edit('a: 1', ['a'], 'a: 1.0', 1.0)
	end

	# A new container is laid out at the indentation of its line.
	def test_a_new_container_is_laid_out_at_the_indentation_of_its_line
		assert_edit("a: {\n\tb: 1\n}\n", ['a', 'b'], "a: {\n\tb: {\n\t\tc: [\n\t\t\t1\n\t\t]\n\t}\n}\n", {'c' => [1]})
	end

	# A new member goes after the last one, and its comment stays on its line.
	def test_a_new_member_goes_after_the_last_one_and_its_comment_stays_on_its_line
		assert_edit("a: {\n\tb: 1 # One\n}\n", ['a', 'c'], "a: {\n\tb: 1 # One\n\tc: 3\n}\n", 3)
		assert_edit('a: 1 # One', ['b'], "a: 1 # One\nb: 2", 2)
	end

	# A new member or item on its own line gets no comma, and the commas of the others stay.
	def test_a_new_member_or_item_on_its_own_line_gets_no_comma_and_the_commas_of_the_others_stay
		assert_edit("a: {\n\tb: 1\n}\n", ['a', 'c'], "a: {\n\tb: 1\n\tc: 3\n}\n", 3)
		assert_edit("a: [\n\t1\n\t2\n]\n", ['a', 2], "a: [\n\t1\n\t2\n\t3\n]\n", 3)
		assert_edit("a: {\n\tb: 1, # One\n}\n", ['a', 'c'], "a: {\n\tb: 1, # One\n\tc: 3\n}\n", 3)
		assert_edit("a: [\n\t1,\n\t2,\n]\n", ['a', 2], "a: [\n\t1,\n\t2,\n\t3\n]\n", 3)
		assert_edit("a: [1 /* x\n*/\n]\n", ['a', 1], "a: [1 /* x\n*/\n2\n]\n", 2)
	end

	# A new member in a one-line object stays on that line.
	def test_a_new_member_in_a_one_line_object_stays_on_that_line
		assert_edit('a: {b: 1}', ['a', 'c'], 'a: {b: 1, c: 2}', 2)
		assert_edit('a: {b: 1,}', ['a', 'c'], 'a: {b: 1, c: 2,}', 2)
		assert_edit('[1, 2]', [2], '[1, 2, 3]', 3)
		assert_edit("a: [\n\t1\n\t2]", ['a', 2], "a: [\n\t1\n\t2, 3]", 3)
	end

	# A new item in an empty container gets its own line, unless the container is inside a container on one line.
	def test_a_new_item_in_an_empty_container_gets_its_own_line_unless_the_container_is_inside_a_container_on_one_line
		assert_edit("a: { # None yet\n}", ['a', 'b'], "a: { # None yet\n\tb: 1\n}", 1)
		assert_edit("a: [\n]", ['a', 0], "a: [\n\t'x'\n]", 'x')
		assert_edit('a: []', ['a', 0], "a: [\n\t'x'\n]", 'x')
		assert_edit('a: [ ]', ['a', 0], "a: [\n\t{\n\t\tb: [\n\t\t\t1\n\t\t]\n\t}\n]", {'b' => [1]})
		assert_edit('deps: {}', ['deps', 'a'], "deps: {\n\ta: '1.0'\n}", '1.0')
		assert_edit('{}', ['a'], "{\n\ta: 1\n}", 1)
		assert_edit('a: [1, []]', ['a', 1, 0], 'a: [1, [2]]', 2)
		assert_edit('a: {b: 1, c: {}}', ['a', 'c', 'd'], 'a: {b: 1, c: {d: [1]}}', [1])
		assert_edit('[/* None yet */]', [0], '[/* None yet */ 1]', 1)
	end

	# A new value in a container on one line is on one line.
	def test_a_new_value_in_a_container_on_one_line_is_on_one_line
		assert_edit('a: [1, 2]', ['a', 2], 'a: [1, 2, {b: 1, c: [true]}]', {'b' => 1, 'c' => [true]})
		assert_edit('a: {x: 1}', ['a', 'x'], 'a: {x: [1, {y: 2}]}', [1, {'y' => 2}])
		assert_edit('a: {x: 1}', ['a', 'y', 'z'], 'a: {x: 1, y: {z: 2}}', 2)
		assert_edit('a: 1', ['a'], "a: {\n\tb: 1\n}", {'b' => 1})
	end

	# Missing objects on the way are created.
	def test_missing_objects_on_the_way_are_created
		assert_edit("x: 1\n", ['a', 'b', 'c'], "x: 1\na: {\n\tb: {\n\t\tc: true\n\t}\n}\n", true)
	end

	# A key that needs quotes is quoted.
	def test_a_key_that_needs_quotes_is_quoted
		assert_edit("x: 1\n", ['the name'], "x: 1\n'the name': 'y'\n", 'y')
		assert_edit("x: 1\n", ['a.b'], "x: 1\n'a.b': 'y'\n", 'y')
		assert_edit("'a.b': 1\na: {b: 2}\n", ['a.b'], "'a.b': 3\na: {b: 2}\n", 3)
	end

	# A removed member takes its line, with the comment at its end.
	def test_a_removed_member_takes_its_line_with_the_comment_at_its_end
		assert_edit("# Head\na: 1 # One\nb: 2\n", ['a'], "# Head\nb: 2\n", delete: true)
		assert_edit("x: [\n\t1,\n\t2, # Two\n\t3,\n]", ['x', 1], "x: [\n\t1,\n\t3,\n]", delete: true)
		assert_edit("[\n\t1, /* a\n\t*/ /* b */\n\t2,\n]", [0], "[\n\t2,\n]", delete: true)
	end

	# A removed item that shares its line takes only itself and its comma, or the comma before it when it is last, so that no trailing comma is left.
	def test_a_removed_item_that_shares_its_line_takes_only_itself_and_its_comma
		assert_edit('x: [1, 2, 3]', ['x', 1], 'x: [1, 3]', delete: true)
		assert_edit('x: [1, 2]', ['x', 1], 'x: [1]', delete: true)
		assert_edit('x: {a: 1, b: 2} # c', ['x', 'b'], 'x: {a: 1} # c', delete: true)
		assert_edit('x: [1 /* c */, 2]', ['x', 1], 'x: [1 /* c */]', delete: true)
		assert_edit("x: [1, 2 # c\n]", ['x', 1], "x: [1\n]", delete: true)
		assert_edit('x: [1, 2 /* c */]', ['x', 1], 'x: [1]', delete: true)
		assert_edit('x: [1, /* c */ 2]', ['x', 1], 'x: [1]', delete: true)
		assert_edit('x: [/* c */ 1, 2]', ['x', 0], 'x: [2]', delete: true)
		assert_edit('x: [/* c */ 1]', ['x', 0], 'x: []', delete: true)
		assert_edit('{x: 1, a: {b: 1, c: 2}}', ['a'], '{x: 1}', delete: true)
		assert_edit('x: [1, 2, 3,]', ['x', 2], 'x: [1, 2,]', delete: true)
		assert_edit("x: [\n\t1, 2,\n]", ['x', 1], "x: [\n\t1,\n]", delete: true)
		assert_edit("/* Note */ a: 1\nb: 2", ['a'], 'b: 2', delete: true)
		assert_edit("# Note\na: 1\nb: 2", ['a'], "# Note\nb: 2", delete: true)
	end

	# A block string that is replaced moves up to the line of its key.
	def test_a_block_string_that_is_replaced_moves_up_to_the_line_of_its_key
		assert_edit("a:\n\t'''\n\tx\n\t'''\nb: 1\n", ['a'], "a: 2\nb: 1\n", 2)
		assert_edit("x: {\n\ta:\n\t\t'''\n\t\tx\n\t\t'''\n}\n", ['x', 'a'], "x: {\n\ta: [\n\t\t1\n\t]\n}\n", [1])
		assert_edit("a: # c\n\t'''\n\tx\n\t'''\n", ['a'], "a: # c\n\t2\n", 2)
	end

	# A removed item leaves a separator between its neighbors.
	def test_a_removed_item_leaves_a_separator_between_its_neighbors
		assert_edit("x: [\n\t1\n\t2\n\t3\n]", ['x', 1], "x: [\n\t1\n\t3\n]", delete: true)
		assert_edit("x: [1, 2\n\t3]", ['x', 1], "x: [1,\n\t3]", delete: true)
		assert_edit("x: [1\n\t2, 3]", ['x', 1], "x: [1\n\t3]", delete: true)
		assert_edit("x: [1, 2\n\t3]", ['x', 0], "x: [2\n\t3]", delete: true)
		assert_edit("x: {a: 1 # One\n\tb: 2}", ['x', 'a'], "x: {\n\tb: 2}", delete: true)
	end

	# The comments that a removed item owns go with it, as the formatter keeps them with it.
	def test_the_comments_that_a_removed_item_owns_go_with_it_as_the_formatter_keeps_them_with_it
		assert_edit('[1 /* a */ , 2]', [0], '[2]', delete: true)
		assert_edit("[1, 2 /* a */ /* b */, # c\n 3]", [1], "[1,\n 3]", delete: true)
		assert_edit('[1, /* a */ 2, 3]', [1], '[1, 3]', delete: true)
		assert_edit('[1 /* a */, 2 /* b */]', [0], '[2 /* b */]', delete: true)
		assert_edit("x: [\n\t1, # a\n\t2\n]", ['x', 0], "x: [\n\t2\n]", delete: true)

		# The removed member is the last one, so it takes the comma before it too.
		assert_edit('{x: 1, a: 2 /* c */}', ['a'], '{x: 1}', delete: true)

		# A comment on a line of its own belongs to no item, so it stays.
		assert_edit("x: [\n\t1\n\t# About 2\n\t2\n]", ['x', 1], "x: [\n\t1\n\t# About 2\n]", delete: true)
		assert_edit("x: [\n\t1\n\n\t# About 2\n\t2\n]", ['x', 1], "x: [\n\t1\n\n\t# About 2\n]", delete: true)
	end

	# A new item goes after the comments that the item before it owns.
	def test_a_new_item_goes_after_the_comments_that_the_item_before_it_owns
		assert_edit('x: [1, 2 /* About 2 */]', ['x', 2], 'x: [1, 2 /* About 2 */, 3]', 3)
		assert_edit("x: [\n\t1\n\t2 # About 2\n]", ['x', 2], "x: [\n\t1\n\t2 # About 2\n\t3\n]", 3)
		assert_edit("x: [\n\t1\n\t# More later\n]", ['x', 1], "x: [\n\t1\n\t2\n\t# More later\n]", 2)

		# An item added to a container that holds only a comment owns that comment, so removing it again removes the comment too.
		assert_edit('x: [/* None yet */]', ['x', 0], 'x: [/* None yet */ 1]', 1)
		assert_edit('x: [/* None yet */ 1]', ['x', 0], 'x: []', delete: true)
	end

	# A removed last member takes the comma before it, with the comments it owns before where its own comma would be.
	def test_a_removed_last_member_takes_the_comma_before_it_and_the_comments_it_owns
		assert_edit('{x: 1, a: 2 /* c */}', ['a'], '{x: 1}', delete: true)
		assert_edit('{x: 1, a: 2 /* c */ }', ['a'], '{x: 1}', delete: true)
		assert_edit("{\n\tx: 1, a: 2 /* c */\n}", ['a'], "{\n\tx: 1\n}", delete: true)

		# One that is not the last keeps the comma before it.
		assert_edit('{x: 1, a: 2 /* c */, y: 4}', ['a'], '{x: 1, y: 4}', delete: true)
	end

	# The same, in the other layouts of the comment, the commas, and the members around them. The expected text is what the JS reference writes.
	def test_a_removed_last_member_with_a_comment_in_other_layouts
		# More comments. The comments of the member that stays stay.
		assert_edit('{x: 1, a: 2 /* c */ /* d */}', ['a'], '{x: 1}', delete: true)
		assert_edit("{x: 1, a: 2 /* c */ # d\n}", ['a'], "{x: 1\n}", delete: true)
		assert_edit('{x: 1 /* e */, a: 2 /* c */}', ['a'], '{x: 1 /* e */}', delete: true)

		# No space after the comma before it, a line break before it, which keeps the comma before it, and an object that is not the document.
		assert_edit('{x: 1,a: 2 /* c */}', ['a'], '{x: 1}', delete: true)
		assert_edit("{x: 1,\n\ta: 2 /* c */}", ['a'], "{x: 1,\n}", delete: true)
		assert_edit("x: {y: 1, a: 2 /* c */}\n", ['x', 'a'], "x: {y: 1}\n", delete: true)

		# The member has a comma after it, which goes with it, so the comma before it stays.
		assert_edit('{x: 1, a: 2 /* c */,}', ['a'], '{x: 1,}', delete: true)

		# A replaced value keeps the comments that its member owns.
		assert_edit('{x: 1, a: 2 /* c */}', ['a'], '{x: 1, a: {q: 1} /* c */}', {'q' => 1})
		assert_edit('{x: 1, a: 2 /* c */}', ['a'], '{x: 1, a: [] /* c */}', [])

		# No member is left, so a comment on a line of its own stays inside the braces, and the comment that the removed member owns goes with it.
		assert_edit("{\n\t# c\n\ta: 1\n}", ['a'], "{\n\t# c\n}", delete: true)
		assert_edit('{a: 1 /* c */}', ['a'], '{}', delete: true)
	end

	# A removed line does not leave two blank lines, or one directly inside a bracket.
	def test_a_removed_line_does_not_leave_two_blank_lines_or_one_directly_inside_a_bracket
		assert_edit("a: 1\n\nb: 2\n\nc: 3\n", ['b'], "a: 1\n\nc: 3\n", delete: true)
		assert_edit("a: 1\n\nb: 2\n", ['b'], "a: 1\n", delete: true)
		assert_edit("{\n\ta: 1,\n\n\tb: 2,\n}\n", ['a'], "{\n\tb: 2,\n}\n", delete: true)
		assert_edit("{\n\ta: 1,\n\n\tb: 2,\n}\n", ['b'], "{\n\ta: 1,\n}\n", delete: true)
		assert_edit("# Lead\n\na: 1\n\nb: 2\n", ['a'], "# Lead\n\nb: 2\n", delete: true)
		assert_edit("\n\ta: 1\n\t\nb: 2\n", ['a'], "\t\nb: 2\n", delete: true)
	end

	# An item after a block comment that starts on an earlier line is indented as that line.
	def test_an_item_after_a_block_comment_that_starts_on_an_earlier_line_is_indented_as_that_line
		assert_edit("{\n\t/* a\n b */ x: 1\n}\n", ['y'], "{\n\t/* a\n b */ x: 1\n\ty: 2\n}\n", 2)
		assert_edit("[\n\t/* a\n b */ 's'\n]\n", [1], "[\n\t/* a\n b */ 's'\n\t1\n]\n", 1)
		assert_edit("{\n\t/* a\n b */ x: 1\n}\n", ['x'], "{\n\t/* a\n b */ x: {\n\t\ta: 1\n\t}\n}\n", {'a' => 1})
	end

	# Removing every item of a container closes it up, unless a comment is left inside.
	def test_removing_every_item_of_a_container_closes_it_up_unless_a_comment_is_left_inside
		assert_edit("a: [\n\t1,\n]\n", ['a', 0], "a: []\n", delete: true)
		assert_edit("{\n\ta: 1,\n}\n", ['a'], "{}\n", delete: true)
		assert_edit("a: [\n\t# Kept\n\t1,\n]\n", ['a', 0], "a: [\n\t# Kept\n]\n", delete: true)
	end

	# Removing the only member of a document without braces leaves an empty object.
	def test_removing_the_only_member_of_a_document_without_braces_leaves_an_empty_object
		assert_edit("# Head\na: 1\n", ['a'], "# Head\n{}\n", delete: true)
		# The comment that the member owned stays.
		assert_edit("a: 1 # note\n", ['a'], "{} # note\n", delete: true)
		assert_edit('{a: 1}', ['a'], '{}', delete: true)
	end

	# Removing a missing value changes nothing.
	def test_removing_a_missing_value_changes_nothing
		assert_edit("a: 1 # One\n", ['b'], "a: 1 # One\n", delete: true)
		assert_edit('a: [1]', ['a', 1], 'a: [1]', delete: true)
	end

	# A block string item before an added or removed item.
	def test_a_block_string_item_before_an_added_or_removed_item
		assert_edit("a: [\n\t'''\n\t\tx\n\t\t'''\n]\n", ['a', 1], "a: [\n\t'''\n\t\tx\n\t\t'''\n\t2\n]\n", 2)
		assert_edit("a: [\n\t'''\n\t\tx\n\t\t'''\n\t2\n]\n", ['a', 0], "a: [\n\t2\n]\n", delete: true)
	end

	# Items of a top-level array.
	def test_items_of_a_top_level_array
		assert_edit("[\n\t1\n\t2\n\t3\n]\n", [1], "[\n\t1\n\t3\n]\n", delete: true)
		assert_edit("[\n\t1\n]\n", [0], "[]\n", delete: true)
		assert_edit("[\n\t/* x\n\t*/ /* y\n\t*/ 1\n]\n", [1], "[\n\t/* x\n\t*/ /* y\n\t*/ 1\n\t2\n]\n", 2)
	end

	# A block string is moved over as a whole.
	def test_a_block_string_is_moved_over_as_a_whole
		assert_edit("s: '''\n\tx\n\t'''\n", ['t'], "s: '''\n\tx\n\t'''\nt: 1\n", 1)
		assert_edit("a: {b: '''\n\tx\n\t'''}", ['a', 'c'], "a: {b: '''\n\tx\n\t''', c: 1}", 1)
	end

	# Properties.

	# Sets or removes the value at `path` in a parsed document, as `SOML.edit` should in the text. Missing objects on the way are created.
	def apply_edit(document, path, value, delete)
		target = document

		path[0...-1].each do |segment|
			target[segment] = {} if target.is_a?(Hash) ? !target.key?(segment) : segment == target.length
			target = target[segment]
		end

		last = path.last

		if delete
			target.is_a?(Array) ? target.delete_at(last) : target.delete(last)
		else
			target[last] = value
		end
	end

	# A path into `document`: to an existing value, to a missing key, or to the end of an array, sometimes with more missing keys after it.
	def random_path(random, values, document)
		path = []
		current = document

		loop do
			keys = current.is_a?(Array) ? current.each_index.to_a : current.keys

			if keys.empty? || random.rand < 0.2
				path << (current.is_a?(Array) ? current.length : missing_key(values, current))
				random.rand(-2..2).times { path << values.key }
				return [path, false]
			end

			key = keys.sample(random:)
			path << key
			child = current[key]
			return [path, true] if !(child.is_a?(Array) || child.is_a?(Hash)) || random.rand < 0.4

			current = child
		end
	end

	def missing_key(values, object)
		key = values.key
		key = values.key while object.key?(key)
		key
	end

	def too_deep?(document)
		SOML.generate(document)
		false
	rescue SOML::GenerateError => error
		raise unless error.reason.include?('nested more than')

		true
	end

	# One random edit of `text`, checked against the same edit of its value.
	def check_random_edit(text, random, label)
		values = TestProperties::Values.new(random)
		formatted = SOML.format(text)
		expected = SOML.parse(text)
		path, exists = random_path(random, values, expected)
		delete = exists && random.rand < 0.3
		value = delete ? nil : values.value(3)
		label = "#{label}: #{path.inspect} #{delete ? 'deleted' : "= #{value.inspect}"}\n#{text}"
		apply_edit(expected, path, value, delete)
		edit = ->(source) { delete ? SOML.edit(source, path, delete: true) : SOML.edit(source, path, value) }

		if too_deep?(expected)
			assert_raises(SOML::GenerateError, label) { edit.(text) }
			return
		end

		edited = edit.(text)
		assert_same_value expected, SOML.parse(edited), "#{label}\n#{edited}"

		# Only the comments inside a replaced or removed value can go away.
		before = SOML::Tree.new(text).then { |tree| tree.comments.map { tree.source.byteslice(it.start, it.finish - it.start) } }
		after = SOML::Tree.new(edited).then { |tree| tree.comments.map { tree.source.byteslice(it.start, it.finish - it.start) } }
		assert after.all? { before.include?(it) }, "#{label}: a comment changed\n#{edited}"
		assert_equal before, after, "#{label}: a comment was lost\n#{edited}" unless exists

		# Setting the same value again changes nothing.
		assert_equal edited, edit.(edited), label unless delete

		# An edit to a formatted document leaves it formatted.
		edited_formatted = edit.(formatted)
		assert_equal edited_formatted, SOML.format(edited_formatted), "#{label}: not formatted\n#{edited_formatted}"
	end

	VALID_CASES.each_with_index do |name, case_index|
		define_method("test_edit_changes_the_value_as_the_same_change_to_the_parsed_value_#{name.delete_suffix('.soml')}") do
			text = File.binread(File.join(ROOT, name)).force_encoding(Encoding::UTF_8)
			random = Random.new(SEED + case_index)

			5.times do
				check_random_edit(text, random, "Seed #{SEED}, #{name}")
			end
		end
	end

	def test_an_edit_of_a_random_document_in_a_random_spelling_changes_the_value_as_the_same_change_to_the_parsed_value
		random = Random.new(SEED)
		values = TestProperties::Values.new(random)
		respeller = TestProperties::Respeller.new(random)

		EXAMPLES.times do
			text = respeller.document(values.document)
			check_random_edit(text, random, "Seed #{SEED}")
		end
	end
end
