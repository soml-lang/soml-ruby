# frozen_string_literal: true

# Runs the language-neutral conformance suite in `conformance/`, a copy of the one in the `soml` spec repository. Edit it there, and update the copy with `../soml/sync-conformance.sh test/conformance`.
#
# - `valid/**/name.soml` must parse to the tagged value in `name.json`, generate exactly `name.canonical.soml` with `canonical: true`, and format to exactly `name.formatted.soml`. The default, which keeps the member order, writes `name.canonical.soml` from itself.
# - `invalid/**/name.soml` must be rejected with the same reason, line, and column as the JS reference, which are in `conformance/invalid-reasons.json`.
# - `edit/name.json` holds a formatted `document`, a `path`, a tagged `value`, which is left out for a removal, and the `expected` document after the change, or `error: true` when the change must fail because its path does not fit the document.
#
# Every file is read in binary mode, so that the UTF-8 checks run too, and no text-mode conversion changes a carriage return.

require_relative 'test_helper'
require 'json'
require 'time'

class TestConformance < Minitest::Test
	ROOT = File.join(__dir__, 'conformance')
	INVALID_REASONS = JSON.parse(File.read(File.join(ROOT, 'invalid-reasons.json')))

	def self.cases(directory)
		Dir.glob('**/*.soml', base: File.join(ROOT, directory))
			.reject { it.end_with?('.canonical.soml', '.formatted.soml') }
			.map { it.delete_suffix('.soml') }
			.sort
	end

	VALID_CASES = cases('valid')
	INVALID_CASES = cases('invalid')
	EDIT_CASES = Dir.glob('*.json', base: File.join(ROOT, 'edit')).map { it.delete_suffix('.json') }.sort

	# Turns the tagged JSON of the suite into the values `SOML.parse` returns.
	def untag(tagged)
		case tagged
		in Array
			tagged.map { untag(it) }
		in {type: String => type, value: String => value} if tagged.length == 2
			case type
			when 'string' then value
			when 'int' then Integer(value, 10)
			when 'float' then {'infinity' => Float::INFINITY, '-infinity' => -Float::INFINITY}.fetch(value) { Float(value) }
			when 'bool' then value == 'true'
			when 'null' then nil
			when 'date' then Date.iso8601(value, Date::GREGORIAN)
			when 'instant' then Time.iso8601(value).utc
			when 'duration' then SOML::Duration.new(nanoseconds: Integer(value, 10))
			else raise "Unknown tag #{type}"
			end
		in Hash
			tagged.to_h { |key, value| [key.to_s, untag(value)] }
		end
	end

	def test_the_suite_is_not_empty
		assert_operator VALID_CASES.length, :>, 300
		assert_operator INVALID_CASES.length, :>, 300
		assert_equal INVALID_CASES.sort, INVALID_REASONS.keys.sort
		assert_operator EDIT_CASES.length, :>, 40
	end

	VALID_CASES.each do |name|
		define_method("test_valid_#{name}") do
			base = File.join(ROOT, 'valid', name)
			bytes = File.binread("#{base}.soml")
			expected = untag(JSON.parse(File.read("#{base}.json"), symbolize_names: true, max_nesting: false))
			canonical = File.binread("#{base}.canonical.soml").force_encoding(Encoding::UTF_8)
			formatted = File.binread("#{base}.formatted.soml").force_encoding(Encoding::UTF_8)

			from_bytes = SOML.parse(bytes)
			assert_same_value expected, from_bytes

			from_string = SOML.parse(bytes.dup.force_encoding(Encoding::UTF_8))
			assert_same_value expected, from_string

			assert_equal canonical, SOML.generate(from_string, canonical: true)

			# Canonical form is a valid document with the same value, and a fixed point. Its members are sorted already, so the default, which keeps their order, writes it too.
			assert_same_value expected, SOML.parse(canonical)
			assert_equal canonical, SOML.generate(SOML.parse(canonical), canonical: true)
			assert_equal canonical, SOML.generate(SOML.parse(canonical))

			assert_equal formatted, SOML.format(bytes)

			# The formatted form is a valid document with the same value, and a fixed point.
			assert_same_value expected, SOML.parse(formatted)
			assert_equal formatted, SOML.format(formatted)
		end
	end

	INVALID_CASES.each do |name|
		define_method("test_invalid_#{name}") do
			bytes = File.binread(File.join(ROOT, 'invalid', "#{name}.soml"))
			error = assert_raises(SOML::ParseError) { SOML.parse(bytes) }
			expected = INVALID_REASONS.fetch(name)
			assert_equal [expected['reason'], expected['line'], expected['column']], [error.reason, error.line, error.column]
		end
	end

	EDIT_CASES.each do |name|
		define_method("test_edit_#{name}") do
			edit_case = JSON.parse(File.read(File.join(ROOT, 'edit', "#{name}.json")), symbolize_names: true)
			document = edit_case[:document]
			expected = edit_case[:expected]
			assert_equal document, SOML.format(document), 'The document is not formatted.'
			change = -> { edit_case.key?(:value) ? SOML.edit(document, edit_case[:path], untag(edit_case[:value])) : SOML.edit(document, edit_case[:path], delete: true) }

			# The error of a path that does not fit the document is a `TypeError` or an `IndexError`, and not the `RuntimeError` of a broken result.
			if edit_case[:error]
				assert_raises(TypeError, IndexError) { change.call }
				return
			end

			assert_equal expected, change.call
			assert_equal expected, SOML.format(expected), 'The result is not formatted.'
		end
	end
end
