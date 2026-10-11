# frozen_string_literal: true

module SOML
	# A length of time, exact to the nanosecond: what a SOML duration such as `1h30m` holds.
	#
	# It is immutable, comparable, and usable as a hash key. A duration is a signed count of nanoseconds in the 64-bit range, about 292 years either way.
	#
	# @!attribute [r] nanoseconds
	#   @return [Integer] The length in nanoseconds.
	#
	# @example
	#   timeout = SOML.parse('timeout: 1m30s')['timeout']
	#   #=> #<SOML::Duration 1m30s>
	#
	#   timeout.to_f
	#   #=> 90.0
	#
	#   SOML::Duration.parse('90s') == timeout
	#   #=> true
	#
	#   SOML::Duration.new(nanoseconds: 1_500_000_000).to_s
	#   #=> "1.5s"
	Duration = Data.define(:nanoseconds) do
		include Comparable

		# Read a duration written as in a document, such as `1h30m`, `1.5s`, or `-250ms`.
		#
		# @param text [String]
		# @return [Duration]
		# @raise [ParseError] When `text` is not a valid duration.
		# @raise [TypeError] When `text` is not a string.
		def self.parse(text) = Parser.new(text).parse_duration_literal

		# Make a duration from a number of seconds, the inverse of {#to_r}. The seconds are rounded to the nearest nanosecond, because a `Float` such as `0.1` is not exact.
		#
		# @param seconds [Numeric] An `Integer`, a `Float`, a `Rational`, or another real number.
		# @return [Duration]
		# @raise [TypeError] When `seconds` is not a number.
		# @raise [RangeError] When `seconds` is not finite, not real, or outside the 64-bit range of nanoseconds.
		#
		# @example
		#   SOML::Duration.from_seconds(90)
		#   #=> #<SOML::Duration 1m30s>
		#
		#   SOML::Duration.from_seconds(0.1)
		#   #=> #<SOML::Duration 0.1s>
		def self.from_seconds(seconds)
			# `Numeric ===` checks the class itself, so an `ActiveSupport::Duration`, which only claims to be a `Numeric`, must be converted with `to_r` first. Its months are an average length.
			raise TypeError, "A duration is made from a number of seconds, got #{Parser.describe_argument(seconds)}" unless Numeric === seconds

			new(nanoseconds: (seconds.to_r * 1_000_000_000).round)
		end

		# @param nanoseconds [Integer] The length in nanoseconds.
		# @raise [TypeError] When `nanoseconds` is not an `Integer`.
		# @raise [RangeError] When `nanoseconds` is outside the 64-bit range.
		def initialize(nanoseconds:)
			raise TypeError, "A duration is a whole number of nanoseconds, got #{Parser.describe_argument(nanoseconds)}" unless Integer === nanoseconds
			raise RangeError, "A duration must be in the 64-bit range of nanoseconds, about 292 years either way, got #{nanoseconds}" unless nanoseconds.between?(INT64_MIN, INT64_MAX)

			super
		end

		# @return [Integer, nil]
		def <=>(other)
			# `Module#===` rather than `is_a?`, which a `BasicObject` does not have.
			nanoseconds <=> other.nanoseconds if Duration === other
		end

		# @return [Boolean]
		def zero? = nanoseconds.zero?

		# @return [Boolean]
		def positive? = nanoseconds.positive?

		# @return [Boolean]
		def negative? = nanoseconds.negative?

		# @return [Duration] The same length in the other direction.
		# @raise [RangeError] For the most negative duration, whose opposite is outside the 64-bit range.
		def -@ = Duration.new(nanoseconds: -nanoseconds)

		# @return [Duration]
		# @raise [RangeError] For the most negative duration, whose length is outside the 64-bit range.
		def abs = negative? ? -self : self

		# A number has no unit, so only a duration can be added.
		#
		# @param other [Duration]
		# @return [Duration]
		# @raise [TypeError] When `other` is not a duration.
		# @raise [RangeError] When the sum is outside the 64-bit range.
		#
		# @example
		#   SOML::Duration.parse('1h') + SOML::Duration.parse('30m')
		#   #=> #<SOML::Duration 1h30m>
		def +(other) = Duration.new(nanoseconds: nanoseconds + nanoseconds_of(other))

		# @param other [Duration]
		# @return [Duration]
		# @raise [TypeError] When `other` is not a duration.
		# @raise [RangeError] When the difference is outside the 64-bit range.
		def -(other) = Duration.new(nanoseconds: nanoseconds - nanoseconds_of(other))

		# @return [Rational] The length in seconds, exactly.
		def to_r = Rational(nanoseconds, 1_000_000_000)

		# @return [Float] The length in seconds, for `sleep` and `Timeout.timeout`.
		def to_f = nanoseconds.fdiv(1_000_000_000)

		# @return [String] The canonical spelling, such as `1h30m`, `1.5s`, or `0s`.
		def to_s
			# Not frozen, as the text that is built below is not.
			return +'0s' if nanoseconds.zero?

			magnitude = nanoseconds.abs
			hours, rest = magnitude.divmod(DURATION_UNITS['h'])
			minutes, rest = rest.divmod(DURATION_UNITS['m'])
			seconds, fraction = rest.divmod(DURATION_UNITS['s'])
			text = nanoseconds.negative? ? +'-' : +''
			text << "#{hours}h" if hours.positive?
			text << "#{minutes}m" if minutes.positive?

			# The fraction is written like an instant's: nine digits with the trailing zeros removed.
			text << "#{seconds}#{Generator.format_fraction(fraction)}s" if seconds.positive? || fraction.positive?

			text
		end

		# @return [String]
		def inspect = "#<SOML::Duration #{self}>"

		# @api private
		def pretty_print(printer) = printer.text(inspect)

		private

		# The message is the one Ruby gives for `1 + nil`.
		def nanoseconds_of(other)
			return other.nanoseconds if Duration === other

			raise TypeError, "#{Parser.conversion_name(other)} can't be coerced into SOML::Duration"
		end
	end
end
