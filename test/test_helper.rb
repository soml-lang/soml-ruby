# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'soml'
require 'minitest/autorun'

module TestHelpers
	# A value with the type of every scalar made explicit, so that a comparison tells `1` from `1.0`, which `==` does not.
	def typed(value)
		case value
		when Hash
			value.to_h { |key, member| [key, typed(member)] }
		when Array
			value.map { typed(it) }
		when String
			[:string, value, value.encoding]
		when Integer
			[:int, value]
		when Float
			[:float, value]
		when true, false
			[:bool, value]
		when nil
			[:null]
		when Date
			[:date, value.year, value.month, value.day, value.gregorian?]
		when Time
			[:instant, value.to_r, value.utc?]
		when SOML::Duration
			[:duration, value.nanoseconds]
		else
			raise "Unexpected #{value.class}"
		end
	end

	def assert_same_value(expected, actual, message = nil)
		assert_equal(typed(expected), typed(actual), message)
	end

	def parse_error(source, **options)
		assert_raises(SOML::ParseError) { SOML.parse(source, **options) }
	end

	def generate_error(value)
		assert_raises(SOML::GenerateError) { SOML.generate(value) }
	end
end

Minitest::Test.include(TestHelpers)
