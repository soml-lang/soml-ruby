# frozen_string_literal: true

require_relative 'test_helper'
require 'date'

class TestDate < Minitest::Test
	VALID_DATES = %w[0001-01-01 9999-12-31 1582-10-10 2011-12-30 2000-02-29 2026-11-01].freeze

	VALID_DATES.each do |text|
		define_method("test_native_date_#{text}") do
			value = SOML.parse("date: #{text}").fetch('date')
			assert_instance_of Date, value
			assert_equal text.split('-').map(&:to_i), [value.year, value.month, value.day]
			assert_equal Date::GREGORIAN, value.start
			assert_equal "date: #{text}\n", SOML.generate({'date' => value}, canonical: true)
		end
	end

	def test_dates_keep_their_type_in_containers_comments_and_adjacent_lines
		source = "[2026-11-01, {date: 1582-10-10} # Comment\n2011-12-30/* Comment */]"
		value = SOML.parse(source)
		assert_instance_of Date, value[0]
		assert_instance_of Date, value[1].fetch('date')
		assert_instance_of Date, value[2]
		assert_equal value, SOML.parse(SOML.generate(value))
		assert_equal value, SOML.parse(SOML.format(source))
	end

	def test_dates_are_distinct_from_strings_and_instants
		value = SOML.parse("date: 2026-11-01\ntext: '2026-11-01'\ntime: 2026-11-01T00:00:00Z")
		assert_instance_of Date, value.fetch('date')
		assert_instance_of String, value.fetch('text')
		assert_instance_of Time, value.fetch('time')
	end

	def test_dates_do_not_depend_on_the_timezone
		timezone = ENV['TZ']
		expected = SOML.parse('a: 1582-10-10')
		['UTC', 'America/Los_Angeles', 'Pacific/Kiritimati'].each do |zone|
			ENV['TZ'] = zone
			assert_same_value expected, SOML.parse('a: 1582-10-10')
			assert_equal "a: 1582-10-10\n", SOML.generate(expected, canonical: true)
		end
	ensure
		ENV['TZ'] = timezone
	end

	def test_date_tokens_and_nodes_have_exact_spans
		tree = SOML.parse_tree("date: 1582-10-10 # Comment\n")
		node = tree.body.members.first.value
		assert_equal :date, node.kind
		assert_instance_of Date, node.value
		assert_equal [6, 16], [node.start, node.finish]
		assert_equal [:bare_key, :punctuator, :date], tree.tokens.map(&:type)
	end

	def test_edits_preserve_native_dates_and_surrounding_source
		date = Date.new(1582, 10, 10, Date::GREGORIAN)
		assert_equal "date: 1582-10-10 # Comment\n", SOML.edit("date: 'old' # Comment\n", ['date'], date)
		assert_equal "[1582-10-10, 2026-11-01]", SOML.edit('[1582-10-10, null]', [1], Date.new(2026, 11, 1))
	end

	def test_invalid_dates_and_longer_tokens_are_rejected
		%w[1900-02-29 2026-02-30 0000-01-01 2026-00-01 2026-13-01 2026-01-00 2026-1-01 10000-01-01 2026-11-01T 2026-11-01Z 2026-11-01foo 2026-11-01T12:00:00 +2026-11-01 -2026-11-01].each do |text|
			assert_raises(SOML::ParseError, text) { SOML.parse("date: #{text}") }
		end
	end

	def test_freezing_a_document_makes_its_dates_shareable
		value = SOML.parse('date: 1582-10-10', freeze: true)
		assert Ractor.shareable?(value)
		assert_equal Date.new(1582, 10, 10, Date::GREGORIAN), value.fetch('date')
	end

	def test_date_subclasses_cannot_override_the_serialized_components
		date_class = Class.new(Date) do
			def year = 0
			def gregorian? = false
			def iso8601 = 'not-a-date'
		end
		assert_equal "date: 1582-10-10\n", SOML.generate({'date' => date_class.new(1582, 10, 10, Date::GREGORIAN)})
	end

	def test_non_ascii_text_after_a_date_reports_a_parse_error
		['😀😀', 'ééé', '日本語'].each do |text|
			error = parse_error("[2026-11-01 #{text}]")
			assert_match(/\AExpected “,”, a line break, or “\]” after an array item, but found/, error.reason)
		end
	end

	def test_date_generation_rejects_values_outside_the_gregorian_contract
		{
			Date.new(0, 1, 1) => 'Cannot generate the date 0000-01-01, because it is outside the years 0001 to 9999',
			Date.new(10_000, 1, 1) => 'Cannot generate the date 10000-01-01, because it is outside the years 0001 to 9999',
			Date.new(1500, 1, 1, Date::JULIAN) => 'Cannot generate the Julian date 1500-01-01. Convert it to a Gregorian Date with new_start(Date::GREGORIAN), which must be in the years 0001 to 9999',
			# A Julian leap day that is not a Gregorian one, which a conversion by components would lose.
			Date.new(1500, 2, 29, Date::JULIAN) => 'Cannot generate the Julian date 1500-02-29. Convert it to a Gregorian Date with new_start(Date::GREGORIAN), which must be in the years 0001 to 9999',
			# The conversion moves this date into year 10000, which cannot be written either.
			Date.new(9999, 12, 31, Date::JULIAN) => 'Cannot generate the Julian date 9999-12-31. Convert it to a Gregorian Date with new_start(Date::GREGORIAN), which must be in the years 0001 to 9999'
		}.each do |date, reason|
			error = generate_error({'date' => date})
			assert_equal [reason, ['date']], [error.reason, error.path]
		end

		error = generate_error({'date' => DateTime.new(2026, 11, 1, 12)})
		assert_equal ['Cannot generate a DateTime. Convert it to a Time with to_time', ['date']], [error.reason, error.path]
	end

	def test_the_suggested_conversion_of_a_julian_date_gives_a_gregorian_date
		date = Date.new(1500, 2, 29, Date::JULIAN)
		assert_equal "date: 1500-03-10\n", SOML.generate({'date' => date.new_start(Date::GREGORIAN)})
	end
end
