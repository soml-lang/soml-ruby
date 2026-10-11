# frozen_string_literal: true

module SOML
	# The writer. It walks the value once and appends to one string, so the time is linear in the output however deep the nesting. It writes canonical form, except that members keep the order of their hash unless `canonical` is true.
	#
	# @api private
	class Generator
		# A byte that cannot be in a `'...'` string: a control character, an apostrophe, or DEL. A string with one is written as `"..."`. The set is a byte table, because a scan of it is faster than the regex it replaces.
		NEEDS_ESCAPED_BYTE = Array.new(256) { |byte| byte < 0x20 || byte == 0x27 || byte == 0x7F }.freeze

		ESCAPED_CHARACTER = /[\x00-\x1F"\\\x7F]/

		# Shareable, so that a ractor can read it.
		ESCAPES = Ractor.make_shareable(
			[*(0x00..0x1F), 0x7F].to_h { |code| [code.chr, format('\\u{%x}', code)] }.merge(
				'"' => '\\"',
				'\\' => '\\\\',
				"\n" => '\\n',
				"\t" => '\\t'
			)
		)

		private_constant :NEEDS_ESCAPED_BYTE, :ESCAPED_CHARACTER, :ESCAPES

		# A key as a document writes it, bare when it can be, for {Parser} to suggest a key and for {Editor} to write a new member.
		#
		# @param key [String] A key that {#member_name} checked.
		# @return [String]
		def self.format_key(key) = SOML.bare_key?(key) ? key : new.generate_value(key, 0)

		# The fraction of a second of an instant or a duration as a document writes it: a point and nine digits with the trailing zeros removed, or nothing when there is none.
		#
		# @param nanoseconds [Integer] The fraction, below one second.
		# @return [String]
		def self.format_fraction(nanoseconds) = nanoseconds.zero? ? '' : ".#{nanoseconds.to_s.rjust(9, '0').rstrip('0')}"

		# @param canonical [Boolean] Whether members are sorted by key, as in canonical form, rather than kept in the order of their hash.
		# @param one_line [Boolean] Whether a container is written on one line, as in `[1, {a: 2}]`, for {Editor} to write a value inside a container that is on one line.
		def initialize(canonical: false, one_line: false)
			@canonical = canonical
			@one_line = one_line
			@line_break = one_line ? '' : "\n"
			@buffer = +''
			@ancestors = {}.compare_by_identity
		end

		# @param value [Hash, Array]
		# @return [String]
		def generate(value)
			case value
			when Hash
				enter(value, 1)

				# A brace-less object needs at least one entry, so the empty object keeps its braces.
				return +"{}\n" if value.empty?

				write_members(value, 1, '')
			when Array
				write_container(value, 1, '')
				@buffer << "\n"
			else
				raise GenerateError, "The top-level value must be a Hash or an Array, because a document is a collection, not #{describe(value)}"
			end

			@buffer
		end

		# One value, for {Editor}. A container's own depth is `depth`, and its lines are indented as if it were at the top level.
		#
		# @param value [Object]
		# @param depth [Integer]
		# @return [String]
		def generate_value(value, depth)
			write_value(value, depth, '')
			@buffer
		end

		# The key as a UTF-8 string, checked outside the block that writes its member, so that an invalid key is reported at the path of its object. {Editor} reads the keys of a path with it too.
		#
		# @param key [String, Symbol]
		# @param written [Boolean] Whether the key is written. A key that is only looked for, as in the path of a removal, may have a carriage return, because no document has such a key, so it finds nothing.
		# @return [String]
		def member_name(key, written: true)
			name = case key
			when String
				to_utf8(key, 'key')
			when Symbol
				to_utf8(key.name, 'key')
			else
				# Only an `Integer` or a `Float` is shown, as in `an Integer (1)`, because `nil`, `true`, and `false` are named already. Anything else, such as an array, or a `Numeric` subclass with its instance variables, can be too deep for `inspect`, which then overflows the machine stack and can crash the process rather than raise, and a `BasicObject` has no `inspect`.
				shown = Integer === key || Float === key ? " (#{key.inspect})" : ''

				raise GenerateError, "A key must be a String or a Symbol, not #{describe(key)}#{shown}, because a key is never converted"
			end

			raise GenerateError, "Cannot generate the key #{Parser.describe_path([name])}, because it contains a carriage return (U+000D), which is not representable" if written && name.include?("\r")

			name
		end

		private

		# Writes a value whose own depth, if it is a container, is `depth`, and whose lines after the first are indented by `indent`.
		def write_value(value, depth, indent)
			case value
			when String
				write_string(value)
			when Integer
				raise GenerateError, "Cannot generate the integer #{value}, because it is outside the 64-bit range" unless value.between?(INT64_MIN, INT64_MAX)

				@buffer << value.to_s
			when Hash, Array
				write_container(value, depth, indent)
			when true
				@buffer << 'true'
			when false
				@buffer << 'false'
			when nil
				@buffer << 'null'
			when Float
				@buffer << format_float(value)
			when Symbol
				write_string(value.name)
			when Time
				@buffer << format_instant(value)
			when Duration
				@buffer << value.to_s
			else
				raise GenerateError, describe_unsupported(value)
			end
		end

		# `@ancestors` holds only the containers on the way to this one, so the same array in two places is written twice, and only an array inside itself is circular.
		def enter(value, depth)
			raise GenerateError, "Cannot generate a value nested more than #{MAX_DEPTH} levels deep" if depth > MAX_DEPTH
			raise GenerateError, 'Cannot generate a circular structure' if @ancestors.key?(value)

			@ancestors[value] = true
		end

		def write_container(value, depth, indent)
			enter(value, depth)
			inner_indent = INDENTS[indent.length + 1]

			if Array === value
				write_array(value, depth, indent, inner_indent)
			else
				write_hash(value, depth, indent, inner_indent)
			end

			@ancestors.delete(value)
		end

		def write_array(array, depth, indent, inner_indent)
			return @buffer << '[]' if array.empty?

			@buffer << '[' << @line_break
			index = 0

			while index < array.length
				@buffer << item_prefix(index, inner_indent)

				begin
					write_value(array[index], depth + 1, inner_indent)
				rescue GenerateError => error
					error.path.unshift(index)
					raise
				end

				@buffer << @line_break
				index += 1
			end

			@buffer << indent unless @one_line
			@buffer << ']'
		end

		def write_hash(hash, depth, indent, inner_indent)
			return @buffer << '{}' if hash.empty?

			@buffer << '{' << @line_break
			write_members(hash, depth, inner_indent)
			@buffer << indent unless @one_line
			@buffer << '}'
		end

		# Writes each member of `hash`, whose own depth is `depth`, on its own line, indented by `indent`, or after a comma on one line.
		def write_members(hash, depth, indent)
			index = 0

			each_member(hash) do |key, member|
				@buffer << item_prefix(index, indent)
				index += 1
				write_key(key)
				@buffer << ': '
				write_value(member, depth + 1, indent)
				@buffer << @line_break
			rescue GenerateError => error
				error.path.unshift(key)
				raise
			end
		end

		# What comes before the member or item at `index` in a container whose members or items are indented by `indent`: a comma and a space after the first one on one line, and otherwise the indentation of a new line.
		def item_prefix(index, indent)
			return indent unless @one_line

			index.zero? ? '' : ', '
		end

		# Yields each member with its key as a UTF-8 string, in the order of the hash, or sorted by key for canonical form.
		def each_member(hash)
			keys = hash.keys
			sort_keys!(keys) if @canonical
			names = {}

			keys.each do |key|
				name = member_name(key)

				# Two keys that are the same string, such as `:a` and `'a'`, would be a duplicate key.
				raise GenerateError, "Cannot generate the key #{Parser.describe_path([name])} twice, because two keys, such as :a and 'a', are the same string" if names.key?(name)

				names[name] = true
				yield name, hash[key]
			end
		end

		# Sorts the keys by their UTF-8 names. UTF-8 byte order is code point order, which is the canonical order.
		def sort_keys!(keys)
			# The common cases, all keys strings or all symbols in UTF-8 or US-ASCII, sort the keys themselves, because then their byte order is the order of their UTF-8 names. A string from `Symbol#to_s` is in US-ASCII. Anything else, such as a symbol in ISO-8859-1, sorts the keys by their UTF-8 names.
			if keys.all? { String === it && utf8_compatible?(it) } || keys.all? { Symbol === it && utf8_compatible?(it) }
				keys.sort!
			else
				keys.sort_by! { member_name(it) }
			end
		end

		def utf8_compatible?(key) = key.encoding == Encoding::UTF_8 || key.encoding == Encoding::US_ASCII

		# A key that `member_name` checked, so it is valid UTF-8 without a carriage return.
		def write_key(key)
			if SOML.bare_key?(key)
				@buffer << key
			else
				write_quoted(key)
			end
		end

		def write_string(string) = write_quoted(to_utf8(string, 'string'))

		# Writes a valid UTF-8 string between quotes, as a `'...'` string when it can be one.
		def write_quoted(string)
			# One scan settles the common case: no quote and no control character.
			index = 0
			length = string.bytesize

			while index < length && !NEEDS_ESCAPED_BYTE[string.getbyte(index)]
				index += 1
			end

			if index == length
				@buffer << "'" << string << "'"
				return
			end

			raise GenerateError, 'Cannot generate a string containing a carriage return (U+000D), which is not representable' if string.include?("\r")

			@buffer << '"' << string.gsub(ESCAPED_CHARACTER, ESCAPES) << '"'
		end

		def to_utf8(string, kind)
			case string.encoding
			when Encoding::UTF_8
				# Already UTF-8.
			when Encoding::BINARY, Encoding::US_ASCII
				# Bytes are read as UTF-8, as `SOML.parse` reads them. A US-ASCII string often holds other bytes, such as a file read with `LANG=C`.
				string = string.dup.force_encoding(Encoding::UTF_8) unless string.ascii_only?
			else
				begin
					string = string.encode(Encoding::UTF_8)
				rescue EncodingError => error
					raise GenerateError, "Cannot generate a #{kind} that cannot be converted to UTF-8: #{error.message}"
				end
			end

			raise GenerateError, "Cannot generate a #{kind} that is not valid #{string.encoding}" unless string.valid_encoding?

			string
		end

		# The shortest decimal that reads back as the same float, laid out as ECMAScript `Number::toString` does, with `.0` added when there is neither a fraction nor an exponent, so that a float never reads back as an int.
		def format_float(value)
			raise GenerateError, 'NaN is not representable. Use nil for a missing value' if value.nan?
			return value.positive? ? 'infinity' : '-infinity' if value.infinite?

			# Covers -0.0 too, since zero has one value whatever its sign.
			return '0.0' if value.zero?

			# `Float#to_s` gives the shortest digits that read back as the same float. Without an exponent, which it uses below 0.0001 and from 1e16, its layout is already canonical.
			text = value.to_s
			return text unless text.include?('e')

			mantissa, exponent = text.delete_prefix('-').split('e')
			whole, fraction = mantissa.split('.')
			digits = "#{whole}#{fraction}".rstrip('0')
			length = digits.length

			# The decimal point is after `point` digits, so the value is 0.digits × 10^point.
			point = exponent.to_i + whole.length

			body = if length <= point && point <= 21
				"#{digits}#{'0' * (point - length)}.0"
			# `Float#to_s` only uses an exponent when the point is outside the digits, so this step of the spec is not reached today. It stays, so that the layout is the spec's whatever `to_s` does.
			elsif point.positive? && point < length
				"#{digits[0, point]}.#{digits[point..]}"
			elsif point > -6 && point <= 0
				"0.#{'0' * -point}#{digits}"
			else
				"#{digits[0]}#{length > 1 ? ".#{digits[1..]}" : ''}e#{point - 1}"
			end

			value.negative? ? "-#{body}" : body
		end

		def format_instant(time)
			# `getutc` makes a copy, which a time in UTC, as `SOML.parse` returns it, does not need.
			utc = time.utc? ? time : time.getutc
			nanoseconds = utc.nsec

			# A time made from a float, such as `Time.at(Time.now.to_f)`, has the float's binary fraction. A subclass of `Time` may define its own `inspect`.
			raise GenerateError, "Cannot generate the instant #{Time.instance_method(:inspect).bind_call(time)}, because it has a fraction of a second finer than a nanosecond. Round it to nanoseconds with time.round(9)" unless (1_000_000_000 % utc.subsec.denominator).zero?
			raise GenerateError, "Cannot generate the instant #{Time.instance_method(:inspect).bind_call(time)}, because in UTC it falls outside the years 0001 to 9999" unless utc.year.between?(1, 9999)

			# The year is 0001 to 9999, so `xmlschema` writes four digits, and a time in UTC ends with `Z`.
			text = utc.xmlschema
			nanoseconds.zero? ? text : "#{text.chop}#{Generator.format_fraction(nanoseconds)}Z"
		end

		# An anonymous class, such as one from `Data.define`, is named by its nearest named superclass.
		def describe(value)
			case value
			when nil, true, false
				value.inspect
			else
				type = Parser.class_of(value)
				named = type
				named = named.superclass until (name = Parser.module_name(named))
				name = Parser.lossy_utf8(named.equal?(type) ? name : "anonymous #{name}")
				"#{name.match?(/\A[AEIOUaeiou]/) ? 'an' : 'a'} #{name}"
			end
		end

		def describe_unsupported(value)
			if defined?(::DateTime) && ::DateTime === value
				'Cannot generate a DateTime. Convert it to a Time with to_time'
			elsif defined?(::Date) && ::Date === value
				"Cannot generate a Date, because a date is not an instant. Write it as a String, such as '#{value}'"
			elsif defined?(::ActiveSupport::Duration) && ::ActiveSupport::Duration === value
				# Rails code writes `5.minutes`. Its days, months, and years follow the calendar, so it is not converted.
				"Cannot generate an ActiveSupport::Duration, because its days, months, and years are not a fixed length. Use a SOML::Duration, such as SOML::Duration.parse('5m')"
			elsif Numeric === value
				"Cannot generate #{describe(value)}. Convert it to an Integer or a Float"
			elsif Struct === value || Data === value
				"Cannot generate #{describe(value)}. Convert it to a Hash with to_h"
			elsif Set === value
				"Cannot generate #{describe(value)}. Convert it to an Array with to_a"
			elsif Pathname === value
				"Cannot generate #{describe(value)}. Convert it to a String with to_s"
			else
				"Cannot generate #{describe(value)}. Only Hash, Array, String, Symbol, Integer, Float, true, false, nil, Time, and SOML::Duration can be generated"
			end
		end
	end
end
