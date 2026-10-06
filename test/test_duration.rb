# frozen_string_literal: true

require_relative 'test_helper'

class TestDuration < Minitest::Test
	def duration(nanoseconds) = SOML::Duration.new(nanoseconds:)

	def test_new_takes_nanoseconds
		assert_equal 90, duration(90).nanoseconds
		assert_equal 90, SOML::Duration.new(90).nanoseconds
	end

	def test_new_refuses_anything_but_an_integer
		assert_equal 'A duration is a whole number of nanoseconds, got 1.5', assert_raises(TypeError) { duration(1.5) }.message
		assert_raises(TypeError) { duration('1') }
		assert_raises(TypeError) { duration(Rational(1, 2)) }
		assert_raises(TypeError) { duration(nil) }
		assert_equal 'A duration is a whole number of nanoseconds, got BasicObject', assert_raises(TypeError) { duration(BasicObject.new) }.message
	end

	# A `SOML::Duration` cannot hold a length outside int64, so the JS checks in `stringify` are checks in its constructor here.
	def test_new_refuses_a_value_outside_the_64_bit_range
		assert_equal(-(2**63), duration(-(2**63)).nanoseconds)
		assert_equal (2**63) - 1, duration((2**63) - 1).nanoseconds
		assert_equal 'A duration must be in the 64-bit range of nanoseconds, about 292 years either way, got 9223372036854775808', assert_raises(RangeError) { duration(2**63) }.message
		assert_raises(RangeError) { duration(-(2**63) - 1) }
		assert_raises(RangeError) { duration(2_562_048 * 3_600_000_000_000) }
	end

	def test_to_s_is_the_canonical_spelling
		{
			0 => '0s',
			1 => '0.000000001s',
			1_500_000_000 => '1.5s',
			250_000 => '0.00025s',
			5_400_000_000_000 => '1h30m',
			3_600_000_000_000 => '1h',
			3_661_000_000_001 => '1h1m1.000000001s',
			-90_000_000_000 => '-1m30s',
			(2**63) - 1 => '2562047h47m16.854775807s',
			-(2**63) => '-2562047h47m16.854775808s'
		}.each do |nanoseconds, text|
			assert_equal text, duration(nanoseconds).to_s
		end
	end

	def test_to_s_is_never_frozen
		refute_predicate duration(0).to_s, :frozen?
		refute_predicate duration(1).to_s, :frozen?
	end

	def test_from_seconds
		assert_equal SOML::Duration.parse('1m30s'), SOML::Duration.from_seconds(90)
		assert_equal SOML::Duration.parse('1.5s'), SOML::Duration.from_seconds(1.5)
		assert_equal SOML::Duration.parse('-250ms'), SOML::Duration.from_seconds(Rational(-1, 4))

		# A Float is not exact, so the seconds are rounded to the nearest nanosecond.
		assert_equal SOML::Duration.parse('100ms'), SOML::Duration.from_seconds(0.1)
		assert_equal duration(333_333_333), SOML::Duration.from_seconds(Rational(1, 3))
		assert_equal duration(1), SOML::Duration.from_seconds(5e-10)
	end

	def test_from_seconds_rounds_exact_ties_to_even
		{
			Rational(1, 2) => 0,
			Rational(-1, 2) => 0,
			Rational(3, 2) => 2,
			Rational(-3, 2) => -2,
			Rational(5, 2) => 2,
			Rational(-5, 2) => -2,
			Rational(7, 2) => 4,
			Rational(-7, 2) => -4,
			Rational(2499, 1000) => 2,
			Rational(-2499, 1000) => -2,
			Rational(2501, 1000) => 3,
			Rational(-2501, 1000) => -3
		}.each do |nanoseconds, expected|
			assert_equal duration(expected), SOML::Duration.from_seconds(nanoseconds / 1_000_000_000), nanoseconds.to_s
		end
	end

	def test_from_seconds_rounds_exact_float_midpoints_and_their_neighbors
		{1 => 976_562, 3 => 2_929_688, 5 => 4_882_812, 7 => 6_835_938}.each do |numerator, expected|
			seconds = numerator.fdiv(1024)
			assert_equal duration(expected), SOML::Duration.from_seconds(seconds)
			assert_equal duration(-expected), SOML::Duration.from_seconds(-seconds)
		end

		seconds = 1.fdiv(1024)
		assert_equal duration(976_562), SOML::Duration.from_seconds(seconds.prev_float)
		assert_equal duration(976_563), SOML::Duration.from_seconds(seconds.next_float)
		assert_equal duration(-976_562), SOML::Duration.from_seconds(-seconds.prev_float)
		assert_equal duration(-976_563), SOML::Duration.from_seconds(-seconds.next_float)
	end

	def test_from_seconds_checks_the_range_after_rounding
		minimum = -(2**63)
		maximum = (2**63) - 1
		{
			Rational(minimum * 2 - 1, 2) => minimum,
			Rational(minimum * 2 + 1, 2) => minimum,
			Rational(maximum * 2 - 1, 2) => maximum - 1,
			maximum + Rational(499, 1000) => maximum
		}.each do |nanoseconds, expected|
			assert_equal duration(expected), SOML::Duration.from_seconds(nanoseconds / 1_000_000_000)
		end

		[minimum - Rational(501, 1000), maximum + Rational(1, 2)].each do |nanoseconds|
			assert_raises(RangeError) { SOML::Duration.from_seconds(nanoseconds / 1_000_000_000) }
		end
	end

	def test_from_seconds_is_the_inverse_of_to_r
		[0, 1, -1, 1_500_000_000, (2**63) - 1, -(2**63)].each do |nanoseconds|
			assert_equal duration(nanoseconds), SOML::Duration.from_seconds(duration(nanoseconds).to_r)
		end
	end

	def test_from_seconds_refuses_anything_but_a_number
		assert_equal 'A duration is made from a number of seconds, got "1"', assert_raises(TypeError) { SOML::Duration.from_seconds('1') }.message
		assert_raises(TypeError) { SOML::Duration.from_seconds(nil) }
		assert_raises(TypeError) { SOML::Duration.from_seconds(duration(1)) }
		assert_equal 'A duration is made from a number of seconds, got BasicObject', assert_raises(TypeError) { SOML::Duration.from_seconds(BasicObject.new) }.message
		assert_raises(RangeError) { SOML::Duration.from_seconds(Float::NAN) }
		assert_raises(RangeError) { SOML::Duration.from_seconds(Float::INFINITY) }
		assert_raises(RangeError) { SOML::Duration.from_seconds(1e20) }
		assert_raises(RangeError) { SOML::Duration.from_seconds(Complex(1, 1)) }
	end

	# `inspect` of a deep value overflows the machine stack, which crashes the process with SIGILL rather than raising, so the message names its class.
	def test_new_and_from_seconds_refuse_a_deeply_nested_value_with_a_type_error
		deep = []
		1_000_000.times { deep = [deep] }
		assert_equal 'A duration is a whole number of nanoseconds, got Array', assert_raises(TypeError) { duration(deep) }.message
		assert_equal 'A duration is made from a number of seconds, got Array', assert_raises(TypeError) { SOML::Duration.from_seconds(deep) }.message

		# A `Numeric` subclass shows its instance variables in `inspect`, so it can be as deep.
		assert_equal 'A duration is a whole number of nanoseconds, got TestDuration::Amount', assert_raises(TypeError) { duration(Amount.new(deep)) }.message
	end

	class Amount < Numeric
		def initialize(parts)
			super()
			@parts = parts
		end
	end

	Span = Struct.new(:nanoseconds)

	# A value that cannot nest is shown as it is written, and anything else by its class.
	def test_a_refused_argument_is_shown_by_its_value_or_its_class
		deep = {}
		300_000.times { deep = {'a' => deep} }
		assert_equal 'A duration is made from a number of seconds, got Hash', assert_raises(TypeError) { SOML::Duration.from_seconds(deep) }.message
		assert_equal 'A duration is made from a number of seconds, got :x', assert_raises(TypeError) { SOML::Duration.from_seconds(:x) }.message
		assert_equal 'A duration is made from a number of seconds, got true', assert_raises(TypeError) { SOML::Duration.from_seconds(true) }.message
		assert_equal 'A duration is a whole number of nanoseconds, got (1/2)', assert_raises(TypeError) { duration(Rational(1, 2)) }.message
		assert_equal 'A duration is a whole number of nanoseconds, got TestDuration::Span', assert_raises(TypeError) { duration(Span.new(1)) }.message
	end

	def test_sign_predicates
		assert_predicate duration(0), :zero?
		refute_predicate duration(1), :zero?
		assert_predicate duration(1), :positive?
		refute_predicate duration(0), :positive?
		assert_predicate duration(-1), :negative?
		refute_predicate duration(0), :negative?
	end

	def test_negation_and_absolute_value
		assert_equal duration(-5), -duration(5)
		assert_equal duration(5), -duration(-5)
		assert_equal duration(5), duration(-5).abs
		assert_equal duration(5), duration(5).abs

		# The 64-bit range has one more negative value than positive ones.
		assert_raises(RangeError) { -duration(-(2**63)) }
		assert_raises(RangeError) { duration(-(2**63)).abs }
	end

	def test_addition_and_subtraction_of_durations
		assert_equal SOML::Duration.parse('1h30m'), SOML::Duration.parse('1h') + SOML::Duration.parse('30m')
		assert_equal SOML::Duration.parse('-30m'), SOML::Duration.parse('1h') - SOML::Duration.parse('1h30m')
		assert_raises(RangeError) { duration((2**63) - 1) + duration(1) }
		assert_raises(RangeError) { duration(-(2**63)) - duration(1) }
	end

	# A number has no unit, so it is not taken as seconds or as nanoseconds.
	def test_addition_and_subtraction_refuse_a_number
		assert_equal "Integer can't be coerced into SOML::Duration", assert_raises(TypeError) { duration(1) + 1 }.message
		assert_equal "nil can't be coerced into SOML::Duration", assert_raises(TypeError) { duration(1) - nil }.message
	end

	def test_inspect
		assert_equal '#<SOML::Duration 1h30m>', duration(5_400_000_000_000).inspect
		assert_equal '#<SOML::Duration -1.5s>', duration(-1_500_000_000).inspect
	end

	def test_pretty_print
		require 'pp'
		assert_equal "#<SOML::Duration 1.5s>\n", duration(1_500_000_000).pretty_inspect
	end

	def test_seconds
		assert_equal Rational(3, 2), duration(1_500_000_000).to_r
		assert_in_delta 1.5, duration(1_500_000_000).to_f
		assert_equal Rational(1, 1_000_000_000), duration(1).to_r
	end

	def test_equality_and_hashing
		assert_equal duration(1), duration(1)
		assert duration(1).eql?(duration(1))
		refute_equal duration(1), duration(2)
		refute_equal duration(1), 1
		assert_equal 1, {duration(5) => true, duration(5) => true}.length
	end

	def test_comparison
		assert_operator duration(1), :<, duration(2)
		assert_equal [duration(-1), duration(0), duration(3)], [duration(3), duration(-1), duration(0)].sort
		assert_nil duration(1) <=> 1
		assert_raises(ArgumentError) { duration(1) < 1 }
	end

	# A `BasicObject` has no `is_a?` or `class`, and an `Integer` compares with it, too.
	def test_a_basic_object_is_not_equal_comparable_or_addable
		other = BasicObject.new
		refute_equal duration(1), other
		refute duration(1).eql?(other)
		assert_nil duration(1) <=> other
		refute_includes [duration(1)], other
		assert_equal "BasicObject can't be coerced into SOML::Duration", assert_raises(TypeError) { duration(1) + other }.message
		assert_equal "BasicObject can't be coerced into SOML::Duration", assert_raises(TypeError) { duration(1) - other }.message
	end

	class Opaque < BasicObject; end

	def test_a_subclass_of_basic_object_is_named_by_its_class_and_cannot_be_ordered
		other = Opaque.new
		refute_equal duration(1), other
		assert_equal "TestDuration::Opaque can't be coerced into SOML::Duration", assert_raises(TypeError) { duration(1) + other }.message
		assert_equal 'A duration is a whole number of nanoseconds, got TestDuration::Opaque', assert_raises(TypeError) { duration(other) }.message
		assert_equal 'A duration is made from a number of seconds, got TestDuration::Opaque', assert_raises(TypeError) { SOML::Duration.from_seconds(other) }.message
		assert_raises(ArgumentError) { duration(1) < other }
		assert_raises(ArgumentError) { duration(1).between?(duration(0), other) }
		assert_raises(ArgumentError) { duration(1).clamp(duration(0), other) }
	end

	def test_is_immutable
		assert_predicate duration(1), :frozen?
		assert_raises(NoMethodError) { duration(1).nanoseconds = 2 }
		assert_raises(FrozenError) { duration(1).instance_variable_set(:@nanoseconds, 2) }
	end

	def test_parse
		assert_equal duration(5_400_000_000_000), SOML::Duration.parse('1h30m')
		assert_equal duration(5_400_000_000_000), SOML::Duration.parse('1.5h')
		assert_equal duration(-250_000_000), SOML::Duration.parse('-250ms')
		assert_equal duration(0), SOML::Duration.parse('0s')
		assert_equal duration(1_000_000), SOML::Duration.parse('1_000us')
	end

	def test_parse_round_trips_to_s
		[0, 1, -1, 999, 1_500_000_000, 5_400_000_000_000, (2**63) - 1, -(2**63)].each do |nanoseconds|
			assert_equal duration(nanoseconds), SOML::Duration.parse(duration(nanoseconds).to_s)
		end
	end

	def test_parse_gives_the_document_errors
		error = assert_raises(SOML::ParseError) { SOML::Duration.parse('1d') }
		assert_equal 'Invalid duration 1d: there is no day unit, because a day is not a fixed length. Write 24h for a fixed 24 hours', error.reason

		error = assert_raises(SOML::ParseError) { SOML::Duration.parse('-0s') }
		assert_equal 'Invalid duration -0s: “-” is not allowed before zero, because zero has one spelling: 0s', error.reason
	end

	def test_parse_refuses_anything_but_one_duration
		['', '30', ' 30s', '30s ', '30s,', '1.5', 'abc', '2026-01-01T00:00:00Z', '0x1F', '30s # comment', "'30s'"].each do |text|
			error = assert_raises(SOML::ParseError, text) { SOML::Duration.parse(text) }
			assert_equal 1, error.line
		end

		assert_equal 'Expected a duration, such as 1h30m, but found “30”', assert_raises(SOML::ParseError) { SOML::Duration.parse('30') }.reason
		assert_equal 'Expected a duration, such as 1h30m, but found “30s ”', assert_raises(SOML::ParseError) { SOML::Duration.parse('30s ') }.reason
		assert_equal 'Expected a duration, such as 1h30m, but found “h30s”', assert_raises(SOML::ParseError) { SOML::Duration.parse('h30s') }.reason
		assert_equal 'Expected a duration, such as 1h30m, but found nothing', assert_raises(SOML::ParseError) { SOML::Duration.parse('') }.reason
		assert_equal 'Expected a duration, such as 1h30m, but found “1s\\n”', assert_raises(SOML::ParseError) { SOML::Duration.parse("1s\n") }.reason
		assert_equal 'Expected a duration, such as 1h30m, but found “1s\\\\n”', assert_raises(SOML::ParseError) { SOML::Duration.parse('1s\n') }.reason
		assert_equal 'Expected a duration, such as 1h30m, but found “"30s"”', assert_raises(SOML::ParseError) { SOML::Duration.parse('"30s"') }.reason
	end

	def test_parse_refuses_a_non_string
		assert_raises(TypeError) { SOML::Duration.parse(30) }
		assert_raises(TypeError) { SOML::Duration.parse(BasicObject.new) }
	end
end
