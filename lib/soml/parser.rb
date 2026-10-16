# frozen_string_literal: true

module SOML
	# A recursive-descent reader over one UTF-8 string. Each method reads one grammar rule at `@index` and moves it past what it read.
	#
	# It is a close port of the JS reference's `parse.ts`, so that the two stay easy to compare and give the same error for every input. It works on byte offsets, because a character index is O(n) on a non-ASCII string, and reads bytes with `getbyte`, with C string searches for long runs. A repeated regex is never run over text of unbounded length, because Onigmo keeps a backtracking entry for every character it repeats over, which is about 50 bytes per character.
	#
	# @api private
	class Parser
		def self.byte_table(characters)
			table = Array.new(256, false)

			characters.each_byte do |byte|
				table[byte] = true
			end

			table.freeze
		end

		private_class_method :byte_table

		# What may directly follow a scalar value: whitespace, a separator, a closing bracket, a comment, or the end.
		VALUE_END_BYTE = byte_table(" \t\n,]}#/")

		DECIMAL_DIGIT = byte_table('0123456789')

		# The first letters of the units, and of a day and a week.
		DURATION_UNIT_START = byte_table('dhmnsuwDHMNSUW')

		# Exact as floats. The fast path divides by at most 10^14.
		POWERS_OF_TEN = Array.new(15) { (10**it).to_f }.freeze
		LETTER = byte_table('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz')

		# The digits, the base, the name, its article, and a search for a character that an error names as an invalid digit, by the byte of the letter of the prefix. A lowercase hexadecimal digit is a digit in the wrong case, so it is not named. Shareable, so that a ractor can read it.
		RADIXES = Ractor.make_shareable({
			0x78 => [byte_table('0123456789ABCDEF'), 16, 'hexadecimal', 'A', /[^0-9A-Fa-f_]/], # x
			0x6F => [byte_table('01234567'), 8, 'octal', 'An', /[^0-7_]/], # o
			0x62 => [byte_table('01'), 2, 'binary', 'A', /[^01_]/] # b
		})

		# The longest token the diagnostic regexes look at, so that a huge invalid token is described from its first part.
		MAX_DIAGNOSED_LENGTH = 1000

		DURATION_UNIT_NAMES = DURATION_UNITS.keys.freeze

		INSTANT_PREFIX = /\A[0-9]{4}-[0-9]{2}-[0-9]{2}/
		INSTANT = /\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})\z/
		LOCAL_DATE_TIME = /\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?\z/
		INSTANT_FORMAT = 'An instant is written as 2026-09-19T14:00:00Z, with an optional fraction of up to nine digits and an offset of Z or ±HH:MM'
		# Uppercase digits too, so that the value of such an escape is checked before its spelling.
		UNICODE_ESCAPE = /\Au\{([0-9A-Fa-f]{1,6})\}/

		# Every C0 control character except tab and line feed, and DEL. They are errors anywhere in a document. The set is for `String#count`, which looks up each byte in a table and is several times as fast as a regex search, so the regex only runs to find where an error is.
		CONTROL_CHARACTERS = "\x00-\x08\x0B-\x1F\x7F"
		CONTROL_CHARACTER = /[#{CONTROL_CHARACTERS}]/

		ESCAPED_STRING_SPECIAL = /[\n"\\]/
		KEY_QUOTING_HINT = '. A key that contains characters other than letters, digits, “_”, and “-” must be quoted'

		# The characters that may be meant as part of a key but are not allowed in a bare key: visible ones that have no meaning in the grammar. A `=` is left out, because after a key, as in `name=foo`, it was most likely meant as the `:` of INI and TOML, so a key that holds a `=` gets no quoting hint.
		# The classes overlap, so they are separate lookaheads, because Onigmo warns about a class with a range twice.
		QUOTABLE_KEY_CHARACTER = /(?!\p{Default_Ignorable_Code_Point})(?!\p{White_Space})[^\p{C}"#'*,\/:=\[\]{}]/

		# The overlap is split in two, for the same reason.
		INVISIBLE_CHARACTER = /\p{Default_Ignorable_Code_Point}|[\p{C}\p{Z}]/

		# Any other character.
		NOT_QUOTABLE_KEY_CHARACTER = /\p{Default_Ignorable_Code_Point}|\p{White_Space}|[\p{C}"#'*,\/:=\[\]{}]/

		SIMPLE_ESCAPES = {
			0x5C => '\\',
			0x22 => '"',
			0x6E => "\n",
			0x74 => "\t"
		}.freeze

		# What a backslash followed by one of these characters was probably meant to be.
		ESCAPE_MISTAKES = {
			'r' => 'There is no \\r escape, because a carriage return cannot be represented',
			"'" => 'A \' needs no escape inside "..."',
			"\n" => 'A backslash must be followed by an escape character. Use \\\\ for a literal backslash, or a \'...\' string'
		}.freeze

		JSON_ESCAPES = {
			'"' => '\\"',
			'\\' => '\\\\',
			"\b" => '\\b',
			"\f" => '\\f',
			"\n" => '\\n',
			"\r" => '\\r',
			"\t" => '\\t'
		}.freeze

		# Names for the characters that are invisible or easy to mistake, so an error can say what it found.
		CHARACTER_NAMES = {
			0x061C => 'ARABIC LETTER MARK',
			0x85 => 'NEXT LINE',
			0xA0 => 'NO-BREAK SPACE',
			0xAD => 'SOFT HYPHEN',
			0x1680 => 'OGHAM SPACE MARK',
			0x2000 => 'EN QUAD',
			0x2001 => 'EM QUAD',
			0x2002 => 'EN SPACE',
			0x2003 => 'EM SPACE',
			0x2004 => 'THREE-PER-EM SPACE',
			0x2005 => 'FOUR-PER-EM SPACE',
			0x2006 => 'SIX-PER-EM SPACE',
			0x2007 => 'FIGURE SPACE',
			0x2008 => 'PUNCTUATION SPACE',
			0x2009 => 'THIN SPACE',
			0x200A => 'HAIR SPACE',
			0x200B => 'ZERO WIDTH SPACE',
			0x200C => 'ZERO WIDTH NON-JOINER',
			0x200D => 'ZERO WIDTH JOINER',
			0x200E => 'LEFT-TO-RIGHT MARK',
			0x200F => 'RIGHT-TO-LEFT MARK',
			0x2028 => 'LINE SEPARATOR',
			0x2029 => 'PARAGRAPH SEPARATOR',
			0x202A => 'LEFT-TO-RIGHT EMBEDDING',
			0x202B => 'RIGHT-TO-LEFT EMBEDDING',
			0x202C => 'POP DIRECTIONAL FORMATTING',
			0x202D => 'LEFT-TO-RIGHT OVERRIDE',
			0x202E => 'RIGHT-TO-LEFT OVERRIDE',
			0x202F => 'NARROW NO-BREAK SPACE',
			0x205F => 'MEDIUM MATHEMATICAL SPACE',
			0x2060 => 'WORD JOINER',
			0x2066 => 'LEFT-TO-RIGHT ISOLATE',
			0x2067 => 'RIGHT-TO-LEFT ISOLATE',
			0x2068 => 'FIRST STRONG ISOLATE',
			0x2069 => 'POP DIRECTIONAL ISOLATE',
			0x3000 => 'IDEOGRAPHIC SPACE',
			0xFEFF => 'ZERO WIDTH NO-BREAK SPACE'
		}.freeze

		# The instant range, checked in UTC, so that every instant has a canonical form that can be read back.
		MIN_INSTANT_SECONDS = -62_135_596_800 # 0001-01-01T00:00:00Z
		MAX_INSTANT_SECONDS = 253_402_300_799 # 9999-12-31T23:59:59Z

		# A character that is invisible, or that a terminal acts on, which `json_quote` leaves as it is.
		UNPRINTABLE = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/

		private_constant(*constants(false))

		# A key as an error message shows it: bare when it can be, and otherwise quoted as `JSON.stringify` quotes it, and cut short when it is long. {Editor} shows the keys of a path the same way.
		#
		# @param key [String]
		# @return [String]
		def self.describe_key(key)
			SOML.bare_key?(key) ? abbreviate(key) : json_quote(abbreviate(key))
		end

		# The keys and indexes of a path as an error message shows them, as in `servers[0].ratio`, with each key as {describe_key} shows it. The keys may come from the caller, perhaps from user input, or from untrusted data, so the path is cut short, and the characters that are invisible or that a terminal acts on become escapes. {Editor} and {GenerateError} show a path with it.
		#
		# @param path [Array<String, Integer>]
		# @return [String]
		def self.describe_path(path)
			description = path.map.with_index do |segment, index|
				if Integer === segment
					"[#{segment}]"
				else
					index.zero? ? describe_key(segment) : ".#{describe_key(segment)}"
				end
			end.join

			abbreviate(description, 200).gsub(UNPRINTABLE) { "\\u{#{it.ord.to_s(16)}}" }
		end

		# Shorten text quoted in an error message, so a huge token does not make a huge message. The length is counted in UTF-16 code units, as the JS reference counts it, so that the two give the same message, and the cut never splits a character.
		def self.abbreviate(text, maximum_length = 40)
			return text if utf16_length(text) <= maximum_length

			length = 0
			kept = text.each_char.take_while { (length += it.bytesize == 4 ? 2 : 1) <= maximum_length }
			"#{kept.join}…"
		end

		# The length of `text` in UTF-16 code units, as JS counts it. A character outside the BMP is two code units, and its UTF-8 lead byte is 0xF0 to 0xF4. `String#count` with that range of characters instead would build a table of a million entries.
		#
		# Note: Not using UTF-16 encoding because it copies the text and is slower for short messages.
		def self.utf16_length(text) = text.length + text.b.count("\xF0-\xF4".b)

		# The string as `JSON.stringify` writes it, as the JS reference shows a quoted key, so that a control character, such as a line feed, shows as its escape.
		def self.json_quote(text) = "\"#{json_escape(text, /["\\\x00-\x1F]/)}\""

		# `text` with the characters that `pattern` matches, which are control characters, `"`, or `\`, written as `JSON.stringify` writes them.
		def self.json_escape(text, pattern) = text.gsub(pattern) { JSON_ESCAPES[it] || format('\\u%04x', it.ord) }

		# A value as Ruby names it in a conversion error, such as `nil` or `Integer` in "nil can't be coerced into Integer", in UTF-8. The class is named with `Module#to_s`, as Ruby names it, because a class can define its own `to_s` that returns anything. {Duration} names a value the same way.
		#
		# @param value [Object]
		# @return [String]
		def self.conversion_name(value)
			case value
			when nil, true, false
				value.inspect
			else
				Error.sanitize(lossy_utf8(Module.instance_method(:to_s).bind_call(class_of(value))))
			end
		end

		# The class of a value, read with `Kernel#class`, which a `BasicObject` does not have.
		#
		# @param value [Object]
		# @return [Class]
		def self.class_of(value) = Kernel.instance_method(:class).bind_call(value)

		# The name of a class, read with `Module#name`, because a class can define its own `name` that returns anything, or `nil` for an anonymous class.
		#
		# @param type [Module]
		# @return [String, nil]
		def self.module_name(type) = Module.instance_method(:name).bind_call(type)

		# Text in UTF-8, so that an error message can join it, such as a class name from a source file in Shift_JIS. Text that does not convert, such as a binary path from `ARGV` with `LANG=C`, or one in an encoding without a converter to UTF-8, has its bytes read as UTF-8, with what is not valid replaced.
		#
		# @param text [String]
		# @return [String]
		def self.lossy_utf8(text)
			converted = begin
				text.encode(Encoding::UTF_8)
			rescue EncodingError
				text.dup.force_encoding(Encoding::UTF_8)
			end

			converted.scrub
		end

		# A value as an argument error shows it: its `inspect` when it cannot nest, as `"1"` or `1.5`, and otherwise its class, as {conversion_name} names it. The `inspect` of a deep value, such as an array in an array a million levels deep, or a `Numeric` subclass that holds one, overflows the machine stack, which can crash the process rather than raise.
		#
		# @param value [Object]
		# @return [String]
		def self.describe_argument(value)
			case value
			when String, Symbol
				# `inspect` escapes a control character, but not a bidirectional control.
				Error.sanitize(value.inspect)
			when Integer, Float, Rational, nil, true, false
				value.inspect
			else
				conversion_name(value)
			end
		end

		# @return [String] The source, in UTF-8.
		attr_reader :source

		# @param source [String]
		# @param path [String, nil] The file the source is from, for the errors.
		def initialize(source, symbolize_names: false, freeze: false, path: nil)
			@path = path
			@source = decode(source)
			@length = @source.bytesize
			@index = 0
			@symbolize_names = symbolize_names
			@freeze = freeze

			# Where the document's collection starts, after the comments and whitespace before it.
			@document_start = 0

			check_characters
		end

		# @return [Hash, Array]
		def parse
			skip_trivia
			@document_start = @index
			fail_at('A document must contain an object or an array, but this one is empty') if @index >= @length

			value = case @source.getbyte(@index)
			when 0x7B # {
				parse_object(1)
			when 0x5B # [
				parse_array(1)
			else
				parse_bare_object
			end

			skip_trivia
			fail_at("Unexpected #{describe_here} after the end of the document") if @index < @length
			@freeze ? Ractor.make_shareable(value) : value
		end

		# The whole source as one duration literal, for {SOML::Duration.parse}.
		#
		# @return [SOML::Duration]
		def parse_duration_literal
			# An empty source and an instant are not duration-like either.
			if number_end(0) < @length || !duration_like?(@source)
				fail_at("Expected a duration, such as 1h30m, but found #{@source.empty? ? 'nothing' : quote_found(abbreviate(@source))}", 0)
			end

			parse_duration(@source, 0)
		end

		private

		def decode(source)
			string = String.try_convert(source)
			raise TypeError, "no implicit conversion of #{Parser.conversion_name(source)} into String" if string.nil?

			# Bytes in a binary or US-ASCII string, as from a file read in binary mode, are read as UTF-8, and `check_characters` reports invalid UTF-8 with its position. Another encoding is converted first, as `JSON.parse` does, which raises an `EncodingError` for a string that does not convert.
			case string.encoding
			when Encoding::UTF_8
				string
			when Encoding::BINARY, Encoding::US_ASCII
				string.dup.force_encoding(Encoding::UTF_8)
			else
				string.encode(Encoding::UTF_8)
			end
		end

		# Characters that are errors wherever they appear, so they are checked once, up front.
		def check_characters
			fail_invalid_utf8 unless @source.valid_encoding?
			fail_at('A byte order mark (BOM) is not allowed', 0) if @source.start_with?("\uFEFF")

			return if @source.count(CONTROL_CHARACTERS).zero?

			index = @source.byteindex(CONTROL_CHARACTER)
			code = @source.getbyte(index)
			fail_at('A carriage return (U+000D) is not allowed anywhere. Use LF line endings', index) if code == 0x0D
			fail_at("A raw control character (#{format_code_point(code)}) is not allowed anywhere, including in strings and comments. In a string, write it as the escape \\u{#{code.to_s(16)}} inside \"...\"", index)
		end

		# Only called on the error path, so it finds the first invalid character one character at a time.
		def fail_invalid_utf8
			offset = 0

			@source.each_char do |character|
				break unless character.valid_encoding?

				offset += character.bytesize
			end

			valid = @source.byteslice(0, offset)

			# A sequence that the end of the input cuts short is reported as what it is.
			if truncated_utf8?(@source.byteslice(offset, @length - offset))
				raise ParseError.new('Incomplete UTF-8 sequence at the end of the input', valid, offset, @path)
			end

			raise ParseError.new(format('Invalid UTF-8 byte 0x%02X', @source.getbyte(offset)), valid, offset, @path)
		end

		# Whether some bytes could follow `rest` to make it one valid character.
		def truncated_utf8?(rest)
			lead = rest.getbyte(0)
			needed = if lead >= 0xF0
				4
			elsif lead >= 0xE0
				3
			else
				2
			end

			return false if rest.bytesize >= needed

			# The next byte is the one with the most constraints, and every byte after it may be any continuation byte.
			(0x80..0xBF).any? do |next_byte|
				candidate = rest.b << next_byte << ("\x80".b * (needed - rest.bytesize - 1))
				candidate.force_encoding(Encoding::UTF_8).valid_encoding?
			end
		end

		def fail_at(reason, offset = @index) = raise(ParseError.new(reason, @source, offset, @path))

		# `bare-object = entry ( entry-sep entry )*`, where a separator is one or more line breaks.
		def parse_bare_object
			object = {}
			start = @index

			begin
				parse_entry(object, 1)
			rescue ParseError => error
				diagnose_bare_value(start)
				raise error
			end

			has_line_break = skip_trivia

			while @index < @length
				fail_at('Top-level entries are separated by line breaks, not commas. Use braces for a one-line object') if @source.getbyte(@index) == 0x2C
				fail_at("Expected a line break before the next entry, but found #{describe_here}#{slash_comment_hint}") unless has_line_break

				parse_entry(object, 1)
				has_line_break = skip_trivia
			end

			object
		end

		# A whole document that is one scalar, such as `5` or an instant, fails as an entry. That failure is reported as what it is.
		def diagnose_bare_value(start)
			@index = start

			is_bare_value = begin
				parse_value(1)
				skip_trivia
				@index >= @length
			rescue ParseError
				# Not a bare value either, so the original error stands.
				false
			end

			fail_at('A bare value is not a document. A document is an object or an array, so write it as `key: value` or `[value]`', start) if is_bare_value
		end

		# Skips spaces, tabs, line breaks, and comments, and returns whether a line break was crossed. A line break inside a block comment does not count.
		def skip_trivia
			source = @source
			index = @index
			has_crossed_line_break = false

			while (byte = source.getbyte(index))
				case byte
				when 0x20, 0x09
					index += 1
				when 0x0A
					has_crossed_line_break = true
					index += 1
				when 0x23 # #
					index = source.byteindex("\n", index) || @length
				when 0x2F # /
					break unless source.getbyte(index + 1) == 0x2A

					index = skip_block_comment(index)
				else
					break
				end
			end

			@index = index
			has_crossed_line_break
		end

		# Returns the index after the block comment that starts at `start`.
		def skip_block_comment(start)
			finish = @source.byteindex('*/', start + 2)
			fail_at('Unterminated block comment', start) if finish.nil?

			nested = @source.byteindex('/*', start + 2)

			# The body may not contain `/*`. An opening that overlaps the closing `*/`, as in `/*/`, is not inside the body.
			fail_at('Block comments cannot be nested, and their body may not contain “/*”', nested) if nested && nested + 2 <= finish

			finish + 2
		end

		# `entry = key ":" ws value`.
		def parse_entry(object, depth)
			key_start = @index
			key = parse_key
			byte = @source.getbyte(@index)
			fail_dot_in_key(key_start) if byte == 0x2E
			fail_missing_colon(key_start) unless byte == 0x3A
			colon = @index
			@index += 1
			skip_trivia

			begin
				value = parse_value(depth + 1)
			rescue ParseError => error
				diagnose_bad_value(error, key, key_start, colon)
				raise
			end

			member = @symbolize_names ? key.to_sym : key
			fail_at("Duplicate key #{Parser.describe_key(key)}", key_start) if object.key?(member)
			object[member] = value
		end

		# Reports a value that failed to parse as what the entry was meant to be, when that is clear.
		def diagnose_bad_value(error, key, key_start, colon)
			# A key that contains a `:`, as in `12:30: 'lunch'`, ends at the first `:`, and the rest is read as the value.
			following = @source.getbyte(colon + 1)
			diagnose_key_with_colon(key_start) if following && BARE_KEY_BYTE[following]

			@index = colon + 1
			is_value_on_next_line = skip_trivia
			value_start = @index
			comment_hint = describe_comment_as_value(colon)
			diagnose_missing_value(value_start, key, key_start, comment_hint) if is_value_on_next_line

			# A value that was left out at the end of the document or of an object. The offset of the error is in characters.
			byte = @source.getbyte(value_start)

			if !comment_hint.empty? && (byte.nil? || byte == 0x7D) && error.offset == @source.byteslice(0, value_start).length
				fail_at("#{error.reason}#{comment_hint}", value_start)
			end
		end

		# A bare key followed directly by `:` and more of a key, up to a `:` that ends the key, as in `a:b: 1`.
		def diagnose_key_with_colon(key_start)
			source = @source
			index = key_start

			while index < key_start + MAX_DIAGNOSED_LENGTH
				byte = source.getbyte(index)

				if byte == 0x3A
					fail_at("A key that contains “:” must be quoted, as in '#{abbreviate(source.byteslice(key_start, index - key_start))}'", key_start) if space_or_line_end?(source.getbyte(index + 1))
				elsif byte.nil? || !BARE_KEY_BYTE[byte]
					return
				end

				index += 1
			end
		end

		# The hint for a `#` directly after a `:`, as in `color: #FFF`, which starts a comment rather than a value.
		def describe_comment_as_value(colon)
			hash = skip_spaces(colon + 1)
			return '' unless @source.getbyte(hash) == 0x23

			# A `#` followed by a space, or by another `#`, starts an ordinary comment. A separator or a closing bracket after the value is not part of it. The regex only sees the start of a long comment, which is cut short in the message anyway.
			match = @source.byteslice(hash, code_unit_end(hash) - hash)[/\A#[^\t\n #,\]}][^\t\n ,\]}]*/]
			match.nil? ? '' : ". “#” starts a comment, so a value that starts with “#” must be quoted#{quoting_example(match)}"
		end

		# An entry whose value was left out, as in `a:` followed by `'b': 1` on the next line, reads the next key as the value. That failure is reported as what it is.
		def diagnose_missing_value(start, parent, key_start, comment_hint)
			# A YAML block sequence.
			first = @source.getbyte(start)
			fail_at('Expected a value, but found a “-” list. An array is written in brackets, as in [80, 443]', start) if first == 0x2D && space?(@source.getbyte(start + 1))

			# Only a key can be followed by its `:`. Reading anything else as a key would make an error, which counts the lines of the whole source, at every level of a nested value.
			return unless first == 0x27 || first == 0x22 || (first && BARE_KEY_BYTE[first])

			@index = start

			key = begin
				parse_key
			rescue ParseError
				# Not a key either, so the original error stands.
				nil
			end

			return unless key && @source.getbyte(@index) == 0x3A

			# Whitespace or the end follows the `:` of a bare key. A digit follows the `:` in an instant such as `2026-09-19T25:00:00Z`, whose own error is more precise. A quoted key cannot be part of a value, so anything may follow its `:`.
			following = @source.getbyte(@index + 1)

			return unless first == 0x27 || first == 0x22 || space_or_line_end?(following)

			hint = comment_hint.empty? ? describe_indented_key(parent, key, key_start, start) : comment_hint
			fail_at("Expected a value, but found the key #{abbreviate(Parser.describe_key(key), 200)}#{hint}", start)
		end

		# The hint for a key at `start` that is indented under the entry whose value is missing, as YAML nests an object.
		def describe_indented_key(parent, key, key_start, start)
			key_indentation = indentation_at(key_start)
			indentation = indentation_at(start)
			return '' if key_indentation.nil? || indentation.nil? || indentation <= key_indentation

			# The keys are written as in a document, so that the suggestion is valid, rather than as JSON strings like the rest of the message, whose escapes, such as `\b`, are not all valid.
			". Indentation does not nest objects, so write #{abbreviate(Generator.format_key(parent), 200)}: {#{abbreviate(Generator.format_key(key), 200)}: …}"
		end

		def fail_missing_colon(key_start)
			source = @source
			following = skip_spaces(@index)
			following_byte = source.getbyte(following)

			fail_at('Whitespace is not allowed between a key and its “:”') if following_byte == 0x3A && following > @index

			# A block comment followed by the ":" was meant to come before it.
			if following_byte == 0x2F && source.getbyte(following + 1) == 0x2A
				comment_end = source.byteindex('*/', following + 2)

				fail_at('A comment is not allowed between a key and its “:”', following) if comment_end && source.getbyte(skip_spaces(comment_end + 2)) == 0x3A
			end

			colon = source.byteindex(':', following)

			# A key with a space in it, such as `the name: 1`. The hint is only given for plain words, because quoting a quoted key would change what it means, and for a `:` that whitespace or the end follows, because quoting the words before the `:` in `server localhost:8080` would give a valid document with another meaning. So `the name:1` gets no hint.
			if colon && following > @index && following_byte && BARE_KEY_BYTE[following_byte] && colon < line_end(following) && space_or_line_end?(source.getbyte(colon + 1))
				# Only spaces and tabs are trimmed, because other Unicode whitespace, such as U+00A0, is not whitespace in SOML.
				key = source.byteslice(key_start, skip_spaces_back(colon) - key_start)
				fail_at("A bare key cannot contain spaces. Quote it, as in '#{abbreviate(key)}'", key_start) if words_with_spaces?(key)
			end

			fail_at('Expected “:” after the key') if @index >= @length || source.getbyte(@index) == 0x0A

			# A character directly after a bare key is most likely meant to be part of it.
			previous = source.getbyte(@index - 1)
			is_after_bare_key = previous != 0x27 && previous != 0x22 && following == @index
			hint = is_after_bare_key && quotable_key_character?(following) ? KEY_QUOTING_HINT : ''
			@index = following
			fail_at("Expected “:” after the key, but found #{describe_here}#{hint}")
		end

		def parse_key
			source = @source
			start = @index
			byte = source.getbyte(start)

			if byte == 0x27 || byte == 0x22
				fail_at('A block string cannot be a key') if source.getbyte(start + 1) == byte && source.getbyte(start + 2) == byte

				# A key is a string, so it may hold anything a string can, including a line feed written as an escape.
				return byte == 0x27 ? parse_literal_string : parse_escaped_string
			end

			finish = start

			while (byte = source.getbyte(finish)) && BARE_KEY_BYTE[byte]
				finish += 1
			end

			if finish == start
				diagnose_table_header if byte == 0x5B
				fail_at(@index >= @length ? 'Expected a key' : "Expected a key, but found #{describe_here}#{key_quoting_hint}#{slash_comment_hint}")
			end

			@index = finish
			source.byteslice(start, finish - start)
		end

		# The hint for a key that starts with a character a bare key cannot hold, such as the `$` in `$schema`, or nothing for a character with another meaning, such as `}`.
		def key_quoting_hint
			return '' unless quotable_key_character?(@index)

			# The key runs to its `:`, and every character before it must be one a quoted key is for. Two searches, because a repeat over a long line needs memory for every character.
			colon = @source.byteindex(':', @index)
			key = @source.byteslice(@index, colon - @index) if colon && colon < line_end(@index)
			# A longer key gets the hint without the example, as in JS, where the key and its `:` must fit in 1000 UTF-16 code units.
			key = nil if key && (Parser.utf16_length(key) >= MAX_DIAGNOSED_LENGTH || key.match?(NOT_QUOTABLE_KEY_CHARACTER))
			key.nil? ? KEY_QUOTING_HINT : "#{KEY_QUOTING_HINT}, as in '#{abbreviate(key)}'"
		end

		# `offset` is before the end of the source.
		def quotable_key_character?(offset) = character_at(offset).match?(QUOTABLE_KEY_CHARACTER)

		# A `.` after a key, as in `example.com: 1`. A key is never a path, so the `.` is meant either as part of the key or as nesting.
		def fail_dot_in_key(key_start)
			source = @source
			finish = @index

			while finish < key_start + MAX_DIAGNOSED_LENGTH && (byte = source.getbyte(finish)) && (BARE_KEY_BYTE[byte] || byte == 0x2E)
				finish += 1
			end

			key = source.byteslice(key_start, finish - key_start)
			# A `-1` limit keeps the empty word after a trailing dot.
			words = key.split('.', -1)

			# The suggestions are only given for a bare key whose dots each have a word on both sides, so that both are valid.
			if source.getbyte(finish) != 0x3A || !BARE_KEY_BYTE[source.getbyte(key_start)] || words.include?('')
				fail_at('A key cannot contain “.” unless it is quoted. Quote the whole key, or use braces to nest, as in a: {b: …}')
			end

			nested = "#{words.last}: …"

			words[...-1].reverse_each do |word|
				nested = "#{word}: {#{nested}}"
			end

			fail_at("A bare key cannot contain “.”. Quote it, as in '#{abbreviate(key)}', or use braces to nest, as in #{abbreviate(nested)}")
		end

		# Found text between curly quotes, as prose quotes it, with its control characters, such as a line feed, written as their JSON escapes, so that they show rather than become U+FFFD, and a backslash escaped, so that it does not read as one of them.
		def quote_found(text) = "“#{Parser.json_escape(text, /[\\\x00-\x1F]/)}”"

		def parse_object(depth)
			object = {}
			parse_items(depth, 0x7D, 'object', 'an object member') { parse_entry(object, depth) }
			object
		end

		def parse_array(depth)
			array = []
			parse_items(depth, 0x5D, 'array', 'an array item') { array << parse_value(depth + 1) }
			array
		end

		# `{` or `[` at depth `depth`, then items, which the block reads, separated by a comma, a line break, or both, with an optional trailing comma, then the `closing` bracket. A comma must be on the line of the item before it.
		def parse_items(depth, closing, kind, item)
			fail_at("The document is nested more than #{MAX_DEPTH} levels deep") if depth > MAX_DEPTH

			source = @source
			start = @index
			@index += 1
			skip_trivia

			until (byte = source.getbyte(@index)) == closing
				has_line_break = false

				if byte
					yield
					item_end = @index
					has_line_break = skip_trivia
					byte = source.getbyte(@index)
				end

				fail_at("Unterminated #{kind}: expected “#{closing.chr}”", start) if byte.nil?

				if byte == 0x2C # ,
					fail_at('A comma must be on the same line as the item before it. The line break already separates the items, so remove the comma') if has_line_break

					@index += 1
					skip_trivia
				elsif !has_line_break && byte != closing
					# Without a line break that separates, a line break in the gap is inside a block comment.
					line_break = source.byteindex("\n", item_end)
					hint = line_break && line_break < @index ? '. A line break inside a block comment does not separate items' : slash_comment_hint
					fail_at("Expected “,”, a line break, or “#{closing.chr}” after #{item}, but found #{describe_here}#{hint}")
				end
			end

			@index += 1
		end

		def parse_value(depth)
			start = @index

			# A container returns directly, because its closing bracket ends it, and the checks below are for what follows a scalar.
			value = case @source.getbyte(@index)
			when 0x7B # {
				return parse_object(depth)
			when 0x5B # [
				return parse_array(depth)
			when 0x27, 0x22 # ' "
				parse_string
			when 0x74 # t
				keyword?('true') ? true : fail_unexpected_value
			when 0x66 # f
				keyword?('false') ? false : fail_unexpected_value
			when 0x6E # n
				keyword?('null') ? nil : fail_unexpected_value
			when 0x69 # i
				keyword?('infinity') ? Float::INFINITY : fail_unexpected_value
			when 0x2D # -
				@source.getbyte(@index + 1) == 0x69 && keyword?('-infinity') ? -Float::INFINITY : (number = parse_number_or_instant)
			when 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39
				number = parse_number_or_instant
			else
				fail_unexpected_value
			end

			# An int or a float written with digits.
			is_number = Integer === number || Float === number
			byte = @source.getbyte(@index)
			fail_after_value(start, is_number) if byte && !VALUE_END_BYTE[byte]
			diagnose_unit_after_space(start) if is_number && space?(byte)
			value
		end

		# A character that cannot follow the value that starts at `start`.
		def fail_after_value(start, is_number)
			byte = @source.getbyte(@index)

			# Go writes microseconds as `µs`, with the micro sign or the Greek letter mu. The duration is only suggested when it is valid, which a number with an exponent or a radix prefix, for example, is not.
			if is_number && (byte == 0xC2 || byte == 0xCE) && ["\u00B5", "\u03BC"].include?(character_at(@index)) && @source.getbyte(@index + 2) == 0x73
				number = @source.byteslice(start, @index - start)
				fail_at("The unit for microseconds is written us#{valid_value?("#{number}us") ? ", as in #{abbreviate(number)}us" : ''}")
			end

			# A `''` inside a '...' string, as SQL and YAML escape a quote, ends the string.
			fail_at('There is no \'\' escape in a \'...\' string. Write a string that contains \' as "...", as in "it\'s"') if byte == 0x27 && @source.getbyte(start) == 0x27

			fail_at("Unexpected #{describe_here} after a value")
		end

		# A number followed by a space and a word, such as `512 MiB` or `10 seconds`, which is an error anyway. A word followed by more than spaces, a separator, or a comment is left to the general errors, because it may be a key, as in `a: 1 b: 2`, or a sentence.
		def diagnose_unit_after_space(start)
			source = @source
			unit_start = skip_spaces(@index)
			unit_end = unit_start

			while (byte = source.getbyte(unit_end)) && LETTER[byte]
				unit_end += 1
			end

			return if unit_end == unit_start

			unit = source.byteslice(unit_start, unit_end - unit_start)

			# A keyword after a number is a missing comma.
			return if !value_end?(skip_spaces(unit_end)) || %w[true false null infinity].include?(unit)

			number = source.byteslice(start, @index - start)
			# The duration is only suggested when it is valid, which a number with an exponent or a radix prefix, a fraction of a nanosecond, a negative zero, or a value outside the 64-bit range is not. The string is always offered, because a unit such as `m` may mean meters rather than minutes.
			duration = DURATION_UNITS.key?(unit) && valid_value?("#{number}#{unit}") ? "#{abbreviate(number)}#{unit}" : '10s'
			fail_at("A unit cannot follow a number after a space. Write a duration without the space, as in #{duration}, and anything else, such as a size, as a string, as in '#{abbreviate("#{number} #{unit}")}'", unit_start)
		end

		def keyword?(word)
			length = word.bytesize

			# A search that finds the word here, which allocates nothing. It only runs where the word is the one valid value, so a search past here is on the way to an error.
			return false unless @source.byteindex(word, @index) == @index

			# A longer word, such as `nullable`, is not the keyword.
			following = @source.getbyte(@index + length)
			return false if following && BARE_KEY_BYTE[following]

			@index += length
			true
		end

		def fail_unexpected_value
			fail_at('Expected a value, but reached the end of the document') if @index >= @length

			byte = @source.getbyte(@index)
			fail_at('A “+” sign is not allowed. A number without a sign is positive') if byte == 0x2B

			# A `.` that no digit follows begins a string, such as `.env` or `./foo`, rather than a number.
			fail_at(digit?(@source.getbyte(@index + 1)) ? 'A number cannot begin with “.”; write a digit before it, as in 0.5' : describe_unknown_word('.', unquoted_text)) if byte == 0x2E

			word_end = @index

			while (byte = @source.getbyte(word_end)) && BARE_KEY_BYTE[byte]
				word_end += 1
			end

			if word_end > @index
				word = @source.byteslice(@index, word_end - @index)

				# A key where a value should be, as when the value of an entry is left out and the next line has a key, or as in `[a: 1]`, is reported as a key. A word after the `:` of a member and a space, as in `msg: Error: file not found` or `url: https://example.com`, is that member's value instead, an unquoted string. Without the space, as in `a:b: 1`, the first `:` was most likely meant as part of the key.
				spaces_start = skip_spaces_back(@index)
				is_member_value = spaces_start < @index && @source.getbyte(spaces_start - 1) == 0x3A
				fail_at("Expected a value, but found the key #{abbreviate(word)}") if !is_member_value && @source.getbyte(word_end) == 0x3A
				diagnose_table_header(true)
				fail_at(describe_unknown_word(word, unquoted_text))
			end

			fail_at("Expected a value, but found #{describe_here}#{block_scalar_indicator? ? '. Write a multiline string as a block string, between \'\'\' lines' : slash_comment_hint}")
		end

		# The text from `start` that was most likely meant as one unquoted string, such as `John Smith`: up to the end of the line, a comma, a closing bracket, or a comment after a space or a tab, without the spaces and tabs at its end. It is read up to 1000 UTF-16 code units, as in JS, and never ends inside a character.
		def unquoted_text(start = @index)
			finish = code_unit_end(start) { unquoted_text_end?(it) }
			@source.byteslice(start, skip_spaces_back(finish) - start)
		end

		def unquoted_text_end?(offset)
			byte = @source.getbyte(offset)
			is_comment = byte == 0x23 || (byte == 0x2F && @source.getbyte(offset + 1) == 0x2A)
			byte == 0x0A || byte == 0x2C || byte == 0x5D || byte == 0x7D || (is_comment && space?(@source.getbyte(offset - 1)))
		end

		# A TOML table header, as in `[server]` or `[[servers]]` on a line of its own, reads as an array that holds a word, or as a key that starts with "[". Where a value is expected, `is_value`, it is only a table header when its bracket opens the document, because a table cannot be written as an item of an array inside it.
		def diagnose_table_header(is_value = false)
			start = line_start(@index)
			return if is_value && skip_spaces(start) != @document_start

			line = @source.byteslice(start, [line_end(@index), code_unit_end(start)].min - start)
			# The name is a valid key, so that the suggestion is valid.
			name = line[/\A[\t ]*\[\[?([A-Z_a-z][0-9A-Z_a-z-]*)\]\]?[\t ]*\z/, 1]
			fail_at("There are no table headers. Write the table as an object, as in #{abbreviate(name)}: {…}") if name
		end

		# A YAML literal block scalar indicator, as in `key: |` or `key: |-`, at the end of its line.
		def block_scalar_indicator?
			# A folded block scalar, `>`, joins its lines, which a block string does not, so only `|` gets the hint.
			return false unless @source.getbyte(@index) == 0x7C

			chomping = @source.getbyte(@index + 1)
			following = @source.getbyte(skip_spaces(chomping == 0x2D || chomping == 0x2B ? @index + 2 : @index + 1))
			following.nil? || following == 0x0A
		end

		# The hint for a `//` comment, as in JavaScript.
		def slash_comment_hint = @source.getbyte(@index) == 0x2F && @source.getbyte(@index + 1) == 0x2F ? '. A comment starts with “#”' : ''

		# The example in a message that a string must be quoted, which quotes `text` as a `'...'` string. That cannot hold a `'`, so then there is no simple example.
		def quoting_example(text) = text.include?("'") ? '' : ", as in '#{abbreviate(text)}'"

		def describe_here
			return 'the end of the document' if @index >= @length

			character = character_at(@index)
			character == "\n" ? 'a line break' : describe_character(character)
		end

		def character_at(offset) = @source.byteslice(offset, 4)[0]

		def parse_string
			source = @source
			quote = source.getbyte(@index)
			return parse_block_string(quote) if source.getbyte(@index + 1) == quote && source.getbyte(@index + 2) == quote

			quote == 0x27 ? parse_literal_string : parse_escaped_string
		end

		# `'...'` has no escapes, so its value is the source text between the quotes.
		def parse_literal_string
			start = @index
			close = @source.byteindex("'", start + 1)
			value = close && @source.byteslice(start + 1, close - start - 1)

			# The search stops at the first quote, so a one-line document with many strings stays linear.
			if value.nil? || value.include?("\n")
				fail_at("Unterminated string. A '...' string must end on the line it starts on; use a block string (''') for multiple lines", start)
			end

			@index = close + 1
			value
		end

		def parse_escaped_string
			source = @source
			start = @index
			close = source.byteindex('"', start + 1)

			# The common case, a string without escapes.
			if close
				value = source.byteslice(start + 1, close - start - 1)

				unless value.include?('\\') || value.include?("\n")
					@index = close + 1
					return value
				end
			end

			value = +''
			chunk_start = start + 1

			loop do
				special = source.byteindex(ESCAPED_STRING_SPECIAL, chunk_start)

				if special.nil? || source.getbyte(special) == 0x0A
					fail_at('Unterminated string. A "..." string must end on the line it starts on; use a block string (""") for multiple lines', start)
				end

				value << source.byteslice(chunk_start, special - chunk_start)

				if source.getbyte(special) == 0x22
					@index = special + 1
					return value
				end

				chunk_start = parse_escape(special, value)
			end
		end

		# Decodes the escape at `offset`, which is a backslash, onto `value`, and returns the offset after it.
		def parse_escape(offset, value)
			source = @source
			byte = source.getbyte(offset + 1)
			simple = SIMPLE_ESCAPES[byte]
			if simple
				value << simple
				return offset + 2
			end

			if byte == 0x75 # u
				# The slice may cut a character in two, which a regex refuses to read.
				match = UNICODE_ESCAPE.match(source.byteslice(offset + 1, 10).scrub)
				fail_at(describe_bad_unicode_escape(source.byteslice(offset + 1, 48).scrub('')[0, 12]), offset) if match.nil?

				hex = match[1]
				code_point = hex.to_i(16)

				# The value is checked before the spelling, so that the uppercase and leading zeros errors never point to an escape that is not allowed either.
				fail_at("A carriage return (U+000D) cannot be represented, so \\u{#{hex}} is not allowed", offset) if code_point == 0x0D
				fail_at("\\u{#{hex}} is a surrogate, which is not a Unicode scalar value", offset) if code_point.between?(0xD800, 0xDFFF)
				fail_at("\\u{#{hex}} is above U+10FFFF, the largest Unicode scalar value", offset) if code_point > 0x10FFFF
				fail_at('A Unicode escape uses lowercase hexadecimal digits', offset) if hex.match?(/[A-F]/)
				fail_at("A Unicode escape may not have leading zeros; write \\u{#{hex.sub(/\A0+(?=.)/, '')}}", offset) if hex.length > 1 && hex.start_with?('0')

				value << code_point
				return offset + 1 + match[0].bytesize
			end

			# A backslash at the end of the document is the same mistake as one at the end of a line.
			character = character_at(offset + 1)
			reason = ESCAPE_MISTAKES[character || "\n"] || "Unknown escape “\\#{character}”. The escapes are \\\\, \\\", \\n, \\t, and \\u{…}; use a '...' string for literal backslashes"
			fail_at(reason, offset)
		end

		# A block string opens with a run of three or more quotes and a line break, and closes at the first line whose first non-whitespace content is a run of exactly that many quotes. The closing line's indentation is removed from every content line, except a blank one, which holds only spaces and tabs and becomes an empty line.
		def parse_block_string(quote)
			source = @source
			start = @index
			delimiter_length = 0
			delimiter_length += 1 while source.getbyte(start + delimiter_length) == quote
			@index = start + delimiter_length

			fail_at('Unterminated block string', start) if @index >= @length

			# As in Swift, the opening delimiter is followed directly by a line break, not even by trailing whitespace.
			fail_at("A block string's opening delimiter must be followed directly by a line break, and its content starts on the next line") unless source.getbyte(@index) == 0x0A

			content_start = @index + 1
			closing_line_start, delimiter_start = find_block_string_end(content_start, quote, delimiter_length)
			fail_at("Unterminated block string#{describe_inline_closing_delimiter(content_start, quote, delimiter_length)}", start) if closing_line_start.nil?

			indentation = source.byteslice(closing_line_start, delimiter_start - closing_line_start)
			@index = delimiter_start + delimiter_length
			lines = []
			line_start = content_start

			while line_start < closing_line_start
				finish = line_end(line_start)
				line = source.byteslice(line_start, finish - line_start)

				# A blank line, which is empty or holds only spaces and tabs, may leave out the indentation, and it becomes an empty line. Swift is stricter here: there only a completely empty line may leave it out.
				if !line.match?(NOT_BLANK_CHARACTER)
					lines << ['', line_start]
				elsif line.start_with?(indentation)
					lines << [line.byteslice(indentation.bytesize, line.bytesize - indentation.bytesize), line_start + indentation.bytesize]
				else
					fail_at("This line does not start with the indentation of its block string's closing delimiter. Every line except a blank one must start with exactly the same spaces and tabs", line_start)
				end

				line_start = finish + 1
			end

			# Blank lines directly after the opening delimiter and directly before the closing one are not content. Every blank line is empty by now.
			first = 0
			last = lines.length
			first += 1 while first < last && lines[first][0].empty?
			last -= 1 while last > first && lines[last - 1][0].empty?
			kept = lines[first...last]

			# `join` of nothing is a US-ASCII string.
			if kept.empty?
				+''
			elsif quote == 0x27
				kept.map(&:first).join("\n")
			else
				kept.map { |text, offset| unescape_line(text, offset) }.join("\n")
			end
		end

		# The hint for a content line that ends with the delimiter, as TOML allows. Adding a closing line after it would keep the delimiter as content.
		def describe_inline_closing_delimiter(content_start, quote, delimiter_length)
			source = @source
			quote_character = quote.chr
			delimiter = quote_character * delimiter_length
			line = source.byteslice(0, content_start).count("\n") + 1
			line_start = content_start

			while line_start < @length
				finish = line_end(line_start)
				text_start = skip_spaces(line_start)
				text_end = skip_spaces_back(finish)
				text = text_end > text_start ? source.byteslice(text_start, text_end - text_start) : ''

				# A line of only quotes, longer than the delimiter, is content.
				return ". Its closing delimiter must start a line, so move the #{delimiter} at the end of line #{line} to a new line" if text.end_with?(delimiter) && text.count(quote_character) != text.bytesize

				line += 1
				line_start = finish + 1
			end

			''
		end

		# Find the closing delimiter of a block string: the first line from `offset` on that holds, after zero or more spaces and tabs, a run of exactly `length` of the `quote` character. A longer run is content. Returns where that line and its delimiter start, or `nil` when no line closes the block.
		def find_block_string_end(offset, quote, length)
			source = @source
			line_start = offset

			while line_start < @length
				delimiter_start = skip_spaces(line_start)
				run_length = 0
				run_length += 1 while source.getbyte(delimiter_start + run_length) == quote
				return [line_start, delimiter_start] if run_length == length

				line_start = line_end(line_start) + 1
			end

			# Past the last line, either because the source ended with a line break or because the last line was content.
			nil
		end

		def unescape_line(text, offset)
			return text unless text.include?('\\')

			value = +''
			chunk_start = 0

			while (index = text.byteindex('\\', chunk_start))
				value << text.byteslice(chunk_start, index - chunk_start)
				chunk_start = parse_escape(offset + index, value) - offset
			end

			value << text.byteslice(chunk_start, text.bytesize - chunk_start)
		end

		def parse_number_or_instant
			plain = parse_plain_number
			return plain unless plain.nil?

			start = @index
			finish = number_end(start)
			text = @source.byteslice(start, finish - start)
			@index = finish

			return parse_instant(text, start) if text.match?(INSTANT_PREFIX)

			kind = classify_number(text)
			return parse_duration(text, start) if kind.nil? && duration_like?(text)

			case kind
			when :decimal, :radix
				fail_at('“-0” is not allowed, because zero has one spelling: 0', start) if text == '-0'
				parse_integer(text, start)
			when :float
				parse_float(text, start)
			else
				fail_at(describe_thousands_separator(text, start) || describe_bad_number(text, unquoted_text(start)), start)
			end
		end

		# A comma used as a thousands separator, as in `[1,000]`, makes the group after it a separate item, which fails only when it has a leading zero. Writing that item in octal, as the leading zero message suggests, would parse to the wrong items.
		def describe_thousands_separator(text, start)
			return unless text.match?(/\A0[0-9]{2}\z/) && byte_before(start) == 0x2C

			group_end = start - 1
			number_start = group_start(group_end)

			# Earlier groups of three digits, as in `12,345,000`.
			while group_end - number_start == 3 && byte_before(number_start) == 0x2C && digit?(byte_before(number_start - 1))
				group_end = number_start - 1
				number_start = group_start(group_end)
			end

			before = byte_before(number_start)

			# The first group has one to three digits, which are not the end of a float, of a number with underscores, or of a number with a radix prefix.
			return if number_start == group_end || before == 0x2E || before == 0x5F || number_start < group_end - 3 || (before && LETTER[before])

			# The sign belongs to the number, as in `-1,000`.
			number_start -= 1 if before == 0x2D

			groups_start = start + text.bytesize
			groups = @source.byteslice(groups_start, code_unit_end(groups_start) - groups_start)[/\A(?:,[0-9]{3}(?![0-9]))*/]
			number = @source.byteslice(number_start, groups_start + groups.bytesize - number_start)
			reason = "Leading zeros are not allowed in a decimal number. A comma separates items, so #{abbreviate(number)} is not one number"
			# Both spellings are the same int, so they are suggested only when it is in range.
			with_underscores = number.tr(',', '_')
			valid_value?(with_underscores) ? "#{reason}. Write it as #{abbreviate(with_underscores)} or #{abbreviate(number.delete(','))}" : reason
		end

		# Where the run of digits that ends at `group_end` starts.
		def group_start(group_end)
			start = group_end
			start -= 1 while digit?(byte_before(start))
			start
		end

		# The common case, a short decimal int or float such as `8080`, `-3`, or `30.5`, without the general path's maximal-run scan and classification. Anything else, including every error, returns `nil` and is left to the general path.
		def parse_plain_number
			source = @source
			start = @index
			index = source.getbyte(start) == 0x2D ? start + 1 : start
			integer_start = index
			value = 0

			# The digits are summed as they are read, so a short number allocates nothing. Only the first 18 are, because the sum is only used for a number that short, and summing a long run in a Bignum would take quadratic time.
			while (byte = source.getbyte(index)) && byte >= 0x30 && byte <= 0x39
				value = (value * 10) + byte - 0x30 if index - integer_start < 18
				index += 1
			end

			integer_length = index - integer_start

			# No digits, or a leading zero followed by more digits, which the general path reports as an error or reads as an instant before the year 1000.
			return if integer_length.zero? || (integer_length > 1 && source.getbyte(integer_start) == 0x30)

			fraction_start = nil

			if byte == 0x2E # .
				fraction_start = index + 1
				index = fraction_start

				while (byte = source.getbyte(index)) && byte >= 0x30 && byte <= 0x39
					value = (value * 10) + byte - 0x30 if index - integer_start < 19
					index += 1
				end

				return if index == fraction_start
			end

			# A character that may continue a number, such as `e`, `_`, or `-`, needs the general path. So does an int with more than 18 digits, which may be outside the 64-bit range, and a float with more than 60 digits, which `String#to_f` does not round correctly.
			length = index - integer_start
			return if (byte && !VALUE_END_BYTE[byte]) || length > (fraction_start ? 61 : 18)

			is_negative = integer_start > start

			if fraction_start
				@index = index

				# With at most 15 digits, the digits and the power of ten are exact as floats, so the quotient is rounded once, which is correct rounding. Without an exponent and with at most 60 digits, a value is far from the float limits, so `to_f` rounds it correctly and never warns.
				value = length <= 16 ? value.to_f / POWERS_OF_TEN[index - fraction_start] : source.byteslice(integer_start, length).to_f

				# Negative zero is the same value as zero.
				return is_negative && !value.zero? ? -value : value
			end

			# `-0` is an error, which the general path reports.
			return if is_negative && value.zero?

			@index = index
			is_negative ? -value : value
		end

		# Whether `text` is a decimal int, a radix int, or a float, following the grammar. A run of digits may have single underscores between digits.
		def classify_number(text)
			radix = text.getbyte(0) == 0x30 && RADIXES[text.getbyte(1)]

			if radix
				finish = skip_digits(text, 2, radix[0])
				return finish > 2 && finish == text.bytesize ? :radix : nil
			end

			index = text.getbyte(0) == 0x2D ? 1 : 0

			# The integer part is `0` or has no leading zero.
			integer_end = skip_integer_part(text, index)
			return if integer_end == index

			index = integer_end
			kind = :decimal

			if text.getbyte(index) == 0x2E # .
				finish = skip_digits(text, index + 1, DECIMAL_DIGIT)
				return if finish == index + 1

				index = finish
				kind = :float
			end

			if text.getbyte(index) == 0x65 # e
				is_negative = text.getbyte(index + 1) == 0x2D
				exponent_start = index + (is_negative ? 2 : 1)

				# The exponent follows the same leading-zero rule as the integer part, and its zero has one spelling, `e0`, so `e-0` is not an exponent.
				finish = is_negative && text.getbyte(exponent_start) == 0x30 ? exponent_start : skip_integer_part(text, exponent_start)
				return if finish == exponent_start

				index = finish
				kind = :float
			end

			index == text.bytesize ? kind : nil
		end

		# Returns the index after a run of digits that may have single underscores between them, or `index` when there is no digit there.
		def skip_digits(text, index, digits)
			byte = text.getbyte(index)
			return index unless byte && digits[byte]

			index += 1

			while (byte = text.getbyte(index))
				if digits[byte]
					index += 1
				elsif byte == 0x5F && (following = text.getbyte(index + 1)) && digits[following]
					index += 2
				else
					break
				end
			end

			index
		end

		# Returns the index after an integer part, which is `0` or digits without a leading zero, or `index` when there is none. Anything after a leading `0`, such as the `5` in `05`, is left for the caller to reject.
		def skip_integer_part(text, index) = text.getbyte(index) == 0x30 ? index + 1 : skip_digits(text, index, DECIMAL_DIGIT)

		# More than 64 significant digits is out of range in any radix, which is decided before a huge digit string is converted.
		def parse_integer(text, start)
			digits = text.delete('_')
			radix = RADIXES[digits.getbyte(1)]
			significant = digits.getbyte(0) == 0x2D ? 1 : 0

			if radix
				significant = 2
				significant += 1 while digits.getbyte(significant) == 0x30
			end

			if digits.bytesize - significant <= 64
				value = radix ? digits.byteslice(significant, digits.bytesize - significant).to_i(radix[1]) : digits.to_i
				return value if value.between?(INT64_MIN, INT64_MAX)
			end

			fail_at("The integer #{abbreviate(text)} is outside the 64-bit range (-9223372036854775808 to 9223372036854775807)", start)
		end

		def parse_float(text, start)
			mantissa, exponent_text = text.delete('_').split('e')
			whole, fraction = mantissa.delete_prefix('-').split('.')
			digits = "#{whole}#{fraction}"
			first = digits.index(/[1-9]/)

			# Negative zero is the same value as zero.
			return 0.0 if first.nil?

			significant = digits.byteslice(first, digits.bytesize - first).rstrip('0')
			# An exponent with more than 18 digits is far outside the float range either way, which is decided before converting a huge digit string, which takes quadratic time.
			exponent_text = exponent_text.start_with?('-') ? '-1000000000000000000' : '1000000000000000000' if exponent_text && exponent_text.delete_prefix('-').bytesize > 18
			exponent = exponent_text.to_i - (fraction&.bytesize || 0) + (digits.bytesize - first - significant.bytesize)

			# A float has at most 767 significant decimal digits, so the digits after the 800th only matter by whether one of them is not zero, which a final 1 stands for. One is, because the trailing zeros are gone.
			if significant.bytesize > 800
				exponent += significant.bytesize - 801
				significant = "#{significant.byteslice(0, 800)}1"
			end

			# The value is at least 10^(magnitude - 1) and below 10^magnitude, which decides the far cases before any big number is made.
			magnitude = exponent + significant.bytesize
			value = if magnitude > 310
				Float::INFINITY
			elsif magnitude < -324
				0.0
			else
				decimal_to_float(significant.to_i, exponent)
			end

			is_negative = mantissa.start_with?('-')
			fail_at("#{abbreviate(text)} is too large to be a finite float. Use #{is_negative ? '-infinity' : 'infinity'} if you mean it", start) if value.infinite?
			fail_at("#{abbreviate(text)} is too small to be told apart from zero. Write 0.0 if you mean zero", start) if value.zero?

			is_negative ? -value : value
		end

		# The float nearest to `significand × 10^exponent`, rounding a tie to even, as IEEE 754 does. It uses exact integer arithmetic rather than `String#to_f`, which warns when a value overflows or underflows.
		#
		# Note: Not using `Float()` because it warns at the limits.
		# Note: Not using `Rational#to_f` because it can round twice (Ruby bug #22246).
		def decimal_to_float(significand, exponent)
			numerator = exponent.negative? ? significand : significand * (10**exponent)
			denominator = exponent.negative? ? 10**-exponent : 1

			# The binary exponent that gives a 53-bit quotient, or the subnormal one, which gives fewer bits.
			shift = [numerator.bit_length - denominator.bit_length - 53, -1074].max
			quotient, remainder = shift.negative? ? (numerator << -shift).divmod(denominator) : numerator.divmod(denominator << shift)

			# The bit lengths estimate the shift to within one.
			if quotient.bit_length > 53
				shift += 1
				quotient, remainder = shift.negative? ? (numerator << -shift).divmod(denominator) : numerator.divmod(denominator << shift)
			end

			divisor = shift.negative? ? denominator : denominator << shift
			comparison = (remainder * 2) <=> divisor
			quotient += 1 if comparison.positive? || (comparison.zero? && quotient.odd?)

			# A quotient of 2^53 and a shift past the largest exponent give infinity.
			Math.ldexp(quotient, shift)
		end

		def parse_instant(text, start)
			unless text.bytesize <= MAX_DIAGNOSED_LENGTH && text.match?(INSTANT)
				# A date, a space, and a time, as TOML and Python write a date and time.
				time_start = @index + 1
				finish = @source.getbyte(@index) == 0x20 && digit?(@source.getbyte(time_start)) ? number_end(time_start) : @index
				time = finish > time_start ? @source.byteslice(time_start, finish - time_start) : ''
				# More of the instant may follow, as in `14:00:00,5Z` or `14:00:00[Europe/Oslo]`, so it may have an offset.
				is_whole_value = value_end?(finish) && !(@source.getbyte(finish) == 0x2C && digit?(@source.getbyte(finish + 1)))
				fail_at(describe_bad_instant(text, time, is_whole_value, offset_after_space), start)
			end

			# The regex checked the layout, so each part is at a fixed offset, except the offset, which follows the optional fraction. Reading the digits as bytes makes no string for each part.
			year = digits_value(text, 0, 4)
			month = digits_value(text, 5, 2)
			day = digits_value(text, 8, 2)
			hour = digits_value(text, 11, 2)
			minute = digits_value(text, 14, 2)
			second = digits_value(text, 17, 2)
			# The offset, `Z` or `±HH:MM`, ends the instant, and a fraction is between the seconds and it.
			# `getbyte(-1)` made parsing a document of many instants a third slower, measured on Ruby 4.0 with YJIT.
			length = text.bytesize
			offset_start = text.getbyte(length - 1) == 0x5A ? length - 1 : length - 6
			fraction_length = offset_start == 19 ? 0 : offset_start - 20

			fail_instant(text, start, 'a fractional second has at most nine digits') if fraction_length > 9
			fail_instant(text, start, 'the year must be 0001 to 9999') if year.zero?
			fail_instant(text, start, 'the month must be 01 to 12') unless month.between?(1, 12)
			last_day = days_in_month(year, month)
			fail_instant(text, start, "the day must be 01 to #{last_day} in that month") unless day.between?(1, last_day)
			fail_instant(text, start, 'the hour must be 00 to 23') if hour > 23
			fail_instant(text, start, 'the minute must be 00 to 59') if minute > 59
			fail_instant(text, start, 'the second must be 00 to 59, and a leap second is not representable') if second > 59

			seconds = (days_from_civil(year, month, day) * 86_400) + (hour * 3600) + (minute * 60) + second
			sign = text.getbyte(offset_start)

			# Not `Z`, so `±HH:MM`.
			if sign != 0x5A
				offset_hour = digits_value(text, offset_start + 1, 2)
				offset_minute = digits_value(text, offset_start + 4, 2)
				fail_instant(text, start, 'the offset hour must be 00 to 23') if offset_hour > 23
				fail_instant(text, start, 'the offset minute must be 00 to 59') if offset_minute > 59
				fail_instant(text, start, '-00:00 means “offset unknown” in RFC 3339, which is not representable; use Z or +00:00') if sign == 0x2D && offset_hour.zero? && offset_minute.zero?
				offset_seconds = (offset_hour * 3600) + (offset_minute * 60)
				seconds += sign == 0x2B ? -offset_seconds : offset_seconds
			end

			fail_instant(text, start, 'in UTC it falls outside the years 0001 to 9999') unless seconds.between?(MIN_INSTANT_SECONDS, MAX_INSTANT_SECONDS)
			Time.at(seconds, fraction_length.zero? ? 0 : digits_value(text, 20, fraction_length) * (10**(9 - fraction_length)), :nsec).utc
		end

		# The value of the `count` decimal digits at `offset` in `text`, which the caller checked are digits.
		#
		# Note: Not using a slice and `to_i` because they are slower for these small fields.
		def digits_value(text, offset, count)
			value = 0
			finish = offset + count

			while offset < finish
				value = (value * 10) + text.getbyte(offset) - 0x30
				offset += 1
			end

			value
		end

		# A scan of the parts in order, so that each error names the part it is about.
		def parse_duration(text, start)
			is_negative = text.getbyte(0) == 0x2D
			index = is_negative ? 1 : 0
			previous_rank = -1
			total = 0

			# The fraction of the last part, and that part's unit size. Only the last part may have one, so the value checks wait until every part is read.
			fraction = ''
			size = 0

			while index < text.bytesize
				digits_end = skip_integer_part(text, index)
				following = text.getbyte(digits_end)

				if digits_end == index
					byte = text.getbyte(index)
					fail_duration(text, start, 'only the whole duration takes a sign, as in -1h30m') if byte == 0x2D && digit?(text.getbyte(index + 1))
					fail_duration(text, start, byte == 0x2B ? 'a “+” sign is not allowed' : "expected a number at “#{abbreviate(text.byteslice(index, text.bytesize - index), 10)}”")
				end

				fail_duration(text, start, 'leading zeros are not allowed') if text.getbyte(index) == 0x30 && (following == 0x5F || digit?(following))
				fail_duration(text, start, 'an underscore must be between two digits') if following == 0x5F

				fraction = ''
				unit_start = digits_end

				if following == 0x2E # .
					unit_start = skip_digits(text, digits_end + 1, DECIMAL_DIGIT)
					fail_duration(text, start, 'a “.” must be followed by a digit') if unit_start == digits_end + 1
					fail_duration(text, start, 'an underscore must be between two digits') if text.getbyte(unit_start) == 0x5F

					# Trailing zeros change nothing, and leaving them out keeps the arithmetic small however many there are.
					fraction = text.byteslice(digits_end + 1, unit_start - digits_end - 1).delete('_').rstrip('0')
				end

				unit_end = unit_start

				while (byte = text.getbyte(unit_end)) && LETTER[byte]
					unit_end += 1
				end

				unit = text.byteslice(unit_start, unit_end - unit_start)
				rank = DURATION_UNIT_NAMES.index(unit)
				fail_duration(text, start, describe_bad_duration_unit(unit, text)) if rank.nil?
				fail_duration(text, start, 'the units are in the order h, m, s, ms, us, ns, and each appears at most once') if rank <= previous_rank
				fail_duration(text, start, 'only the last part may have a fraction') if following == 0x2E && digit?(text.getbyte(unit_end))

				size = DURATION_UNITS[unit]

				# More than 19 digits, which with the single underscores that may be between them is more than 37 bytes, is out of range in any unit, which is decided before a huge digit string is converted. `to_i` reads the underscores.
				total += digits_end - index > 37 ? INT64_MAX * 2 : text.byteslice(index, digits_end - index).to_i * size
				index = unit_end
				previous_rank = rank
			end

			# More than 13 fraction digits without a trailing zero is finer than a nanosecond in any unit, which is decided before a huge digit string is converted.
			fail_duration(text, start, 'it is not a whole number of nanoseconds') if fraction.bytesize > 13

			unless fraction.empty?
				scale = 10**fraction.bytesize
				fraction_nanoseconds = fraction.to_i * size
				# Note: Not using `divmod` because it allocates an array and is slower for ordinary short fractions.
				fail_duration(text, start, 'it is not a whole number of nanoseconds') unless (fraction_nanoseconds % scale).zero?
				total += fraction_nanoseconds / scale
			end

			fail_duration(text, start, '“-” is not allowed before zero, because zero has one spelling: 0s') if is_negative && total.zero?
			fail_duration(text, start, 'it is outside the 64-bit range of nanoseconds, about 292 years either way') if total > (is_negative ? -INT64_MIN : INT64_MAX)

			Duration.new(nanoseconds: is_negative ? -total : total)
		end

		def fail_instant(text, start, reason) = fail_at("Invalid instant #{abbreviate(text)}: #{reason}", start)

		def fail_duration(text, start, reason) = fail_at("Invalid duration #{abbreviate(text)}: #{reason}", start)

		# Whether a token that is not a number or an instant was meant as a duration: its first letter could begin a unit, or a day or a week. A radix prefix, an exponent, and other letters, such as the `T` in `20260919T140000Z` or the `x` in `1.5x`, are left to the number errors.
		def duration_like?(text)
			index = text.getbyte(0) == 0x2D ? 1 : 0
			return false unless digit?(text.getbyte(index))

			index += 1 while digit_or_underscore?(text.getbyte(index))

			if text.getbyte(index) == 0x2E
				index += 1
				index += 1 while digit_or_underscore?(text.getbyte(index))
			end

			byte = text.getbyte(index)
			return false if byte.nil?

			# A year unit, as in `1y` or `2years`, is only one when the token or another part follows it, so that a word such as `100yen` stays a string to quote. The longest unit and the byte after it fit in 6 bytes.
			DURATION_UNIT_START[byte] || text.byteslice(index, 6).match?(/\A(?:y|yrs?|years?)(?:\z|[0-9])/i)
		end

		def line_end(offset) = @source.byteindex("\n", offset) || @length

		def line_start(offset) = offset.zero? ? 0 : (@source.byterindex("\n", offset - 1) || -1) + 1

		# The number of spaces and tabs before `offset` on its line, or `nil` when something else comes before it.
		def indentation_at(offset)
			start = line_start(offset)
			skip_spaces(start) == offset ? offset - start : nil
		end

		# The end of the number, instant, or duration that starts at `start`: the end of the run of the bytes that one can hold.
		def number_end(start)
			finish = start

			while (byte = @source.getbyte(finish)) && NUMBER_BYTE[byte]
				finish += 1
			end

			finish
		end

		# The offset after `maximum` UTF-16 code units from `start`, as JS slices the source, or before the first character for which the block returns true. A character outside the BMP that JS cuts in two at the limit is kept whole, so that, like the lone surrogate JS keeps, it is still there to stop a match at the end.
		def code_unit_end(start)
			finish = start
			length = 0

			while (byte = @source.getbyte(finish))
				# A continuation byte is part of the character before it.
				unless byte.between?(0x80, 0xBF)
					break if length >= MAX_DIAGNOSED_LENGTH || (block_given? && yield(finish))

					# A character outside the BMP is two UTF-16 code units, and its UTF-8 lead byte is 0xF0 to 0xF4.
					length += byte >= 0xF0 ? 2 : 1
				end

				finish += 1
			end

			finish
		end

		# Whether a value ends at `offset`, so that a suggestion that ends there leaves nothing out: at the end, whitespace, a separator, a closing bracket, or a comment. A `/` only starts a comment with a `*` after it, or a `//` comment of another language, which the error for what follows names, so in `km/h` the text goes on.
		def value_end?(offset)
			byte = @source.getbyte(offset)
			byte.nil? || (VALUE_END_BYTE[byte] && (byte != 0x2F || (following = @source.getbyte(offset + 1)) == 0x2A || following == 0x2F))
		end

		def byte_before(offset) = offset.positive? ? @source.getbyte(offset - 1) : nil

		def skip_spaces(offset)
			offset += 1 while space?(@source.getbyte(offset))
			offset
		end

		def space?(byte) = byte == 0x20 || byte == 0x09

		# Whether a byte is a space, a tab, a line feed, or the end.
		def space_or_line_end?(byte) = byte.nil? || byte == 0x0A || space?(byte)

		def skip_spaces_back(offset)
			offset -= 1 while offset.positive? && space?(@source.getbyte(offset - 1))
			offset
		end

		def digit?(byte) = !byte.nil? && byte >= 0x30 && byte <= 0x39

		def digit_or_underscore?(byte) = byte == 0x5F || digit?(byte)

		# Note: Not using `String#count` because it scans the whole input even when its first character is invalid.
		def words_with_spaces?(text) = !text.match?(/[^A-Za-z0-9_ \t-]/)

		def days_in_month(year, month)
			if month == 2
				# Note: Not using `Date.gregorian_leap?` because it is slower and would require loading `date`.
				is_leap_year = (year % 4).zero? && (!(year % 100).zero? || (year % 400).zero?)
				return is_leap_year ? 29 : 28
			end

			[4, 6, 9, 11].include?(month) ? 30 : 31
		end

		# Days since 1970-01-01 in the proleptic Gregorian calendar, from Howard Hinnant's `days_from_civil`.
		#
		# Note: Not using `Time.utc` because constructing it here is slower.
		def days_from_civil(year, month, day)
			year -= 1 if month <= 2
			era = year.div(400)
			year_of_era = year - (era * 400)
			day_of_year = ((153 * (month + (month > 2 ? -3 : 9))) + 2) / 5 + day - 1
			day_of_era = (year_of_era * 365) + (year_of_era / 4) - (year_of_era / 100) + day_of_year
			(era * 146_097) + day_of_era - 719_468
		end

		def abbreviate(...) = Parser.abbreviate(...)

		def format_code_point(code_point) = format('U+%04X', code_point)

		# Describe a character for an error message, such as `“$”` or `U+00A0 (NO-BREAK SPACE)`.
		def describe_character(character)
			code_point = character.ord
			name = CHARACTER_NAMES[code_point]

			if name
				is_whitespace = character.match?(/[\p{White_Space}\u200B\uFEFF]/)
				return "#{format_code_point(code_point)} (#{name}#{is_whitespace ? '; only space, tab, and line feed are whitespace' : ''})"
			end

			# Control, format, private-use, unassigned, surrogate, separator, and default-ignorable characters are invisible or ambiguous, so they are shown by code point.
			code_point != 0x20 && character.match?(INVISIBLE_CHARACTER) ? format_code_point(code_point) : "“#{character}”"
		end

		# `text` is the unquoted string that `word` begins, which the suggestion quotes.
		def describe_unknown_word(word, text)
			# A keyword hint is only for the word on its own. In `Yes please` or `Nan Goldin`, following it would leave text behind or change the value.
			lowercase = text == word ? word.downcase : ''

			case lowercase
			when 'true', 'false', 'yes', 'no', 'on', 'off'
				"“#{word}” is not a value. Booleans are written true and false, in lowercase"
			when 'null', 'nil', 'none', 'undefined'
				"“#{word}” is not a value. Null is written null, in lowercase"
			when 'nan'
				'NaN is not representable. Use null for a missing value'
			when 'inf', 'infinity'
				"“#{word}” is not a value. Infinity is written infinity, in lowercase"
			else
				"Unexpected “#{abbreviate(word)}”. A string value must be quoted#{quoting_example(text)}"
			end
		end

		def describe_bad_unicode_escape(rest)
			if rest.match?(/\Au[0-9A-Fa-f]{4}/)
				describe_four_digit_escape(rest)
			elsif rest.match?(/\Au\{[0-9A-Fa-f]*[A-F]/)
				'A Unicode escape uses lowercase hexadecimal digits'
			elsif rest.start_with?('u{}')
				'A Unicode escape needs one to six hexadecimal digits'
			elsif rest.match?(/\Au\{[0-9a-f]{7}/)
				'A Unicode escape has at most six hexadecimal digits'
			else
				'A Unicode escape is written \\u{…} with one to six lowercase hexadecimal digits'
			end
		end

		# The JSON form `\uXXXX`, from its `u`, with the escape to write instead. JSON writes a character above U+FFFF as two of them, a surrogate pair, which is one `\u{…}` escape here. Here, a lone surrogate and a carriage return have no escape.
		def describe_four_digit_escape(rest)
			code = rest[1, 4].to_i(16)
			low = rest[5..].match?(/\A\\u[0-9A-Fa-f]{4}/) ? rest[7, 4] : nil
			low_code = low&.to_i(16)

			if code.between?(0xD800, 0xDBFF) && low_code&.between?(0xDC00, 0xDFFF)
				code_point = 0x10000 + ((code - 0xD800) * 0x400) + (low_code - 0xDC00)
				return "The four-digit \\#{rest[0, 5]}\\u#{low} form is not an escape. Write \\u{#{code_point.to_s(16)}}"
			end

			form = "The four-digit \\#{rest[0, 5]} form is not an escape"

			if code.between?(0xD800, 0xDFFF)
				"#{form}, and a lone surrogate is not a Unicode scalar value. Write the character it is half of as one \\u{…} escape"
			elsif code == 0x0D
				"#{form}, and a carriage return (U+000D) cannot be represented"
			else
				"#{form}. Write \\u{#{code.to_s(16)}}"
			end
		end

		def describe_bad_duration_unit(unit, text)
			if unit.empty?
				'every number needs a unit: h, m, s, ms, us, or ns'
			elsif unit.match?(/\Ad(?:ays?)?\z/)
				'there is no day unit, because a day is not a fixed length. Write 24h for a fixed 24 hours'
			elsif unit.match?(/\Aw(?:eeks?)?\z/)
				'there is no week unit, because a day is not a fixed length. Write 168h for a fixed 168 hours'
			elsif unit.match?(/\A(?:y|yrs?|years?)\z/i)
				'there is no year unit, because a year is not a fixed length. Write 8760h for a fixed 365 days'
			elsif unit == 'M'
				# A number with `M` alone is more often a size, as in `memory: 512M`, and `512m` would read as minutes.
				# Whether the text is digits and underscores before the `M`, found with a search for one other character, because a repeat over a long token needs memory for every character.
				is_size = text.bytesize <= MAX_DIAGNOSED_LENGTH && digit?(text.getbyte(0)) && !text.byteslice(0, text.bytesize - 1).match?(/[^0-9_]/)
				size_hint = is_size ? ". A size, such as 512M, is a string: '#{abbreviate(text)}'" : ''
				"there is no month unit, because a month is not a fixed length#{size_hint}"
			elsif DURATION_UNITS.key?(unit.downcase)
				"the units are lowercase: #{unit.downcase}"
			else
				"“#{abbreviate(unit, 10)}” is not a unit. The units are h, m, s, ms, us, and ns, and a string must be quoted"
			end
		end

		# `unquoted_text` is the unquoted string that `full_text` begins, for the suggestion to quote it.
		def describe_bad_number(full_text, unquoted_text)
			text = full_text.byteslice(0, MAX_DIAGNOSED_LENGTH)

			return 'A “+” sign is not allowed in a number, including in an exponent' if text.include?('+')
			return 'A number prefix is lowercase: 0x, 0o, or 0b' if text.match?(/\A-?0[BOX]/)

			# The whole number, not the part cut at the diagnosed length, because a cut can end before the digit or the underscore that the message is about. Each check below takes linear time.
			sign_length = full_text.getbyte(0) == 0x2D ? 1 : 0
			radix = full_text.getbyte(sign_length) == 0x30 && RADIXES[full_text.getbyte(sign_length + 1)]

			if radix
				_, base, name, article, invalid_character = radix
				prefix_end = sign_length + 2
				digits = full_text.byteslice(prefix_end, full_text.bytesize - prefix_end)

				return "#{article} #{name} integer cannot have a sign, because it states a bit pattern rather than a quantity" if sign_length == 1
				return "Expected #{name} digits after “#{full_text.byteslice(0, 2)}”" if digits.empty?

				# A search for one character, because a repeat over a long number needs memory for every character.
				character = digits[invalid_character]

				if base == 16 && character.nil? && digits.match?(/[a-f]/)
					# The uppercase spelling is only suggested when it is valid, so a misplaced underscore is reported first, and a value outside the 64-bit range gets no example.
					return 'An underscore in a number must be between two digits' if digits.start_with?('_') || digits.end_with?('_') || digits.include?('__')

					uppercase = "0x#{digits.upcase}"
					return valid_value?(uppercase) ? "Hexadecimal digits are uppercase: #{abbreviate(uppercase)}" : 'Hexadecimal digits are uppercase'
				end

				return character.nil? ? 'An underscore in a number must be between two digits' : "Invalid #{name} digit “#{character}”"
			end

			# Only when the “E” is where an exponent marker goes, with digits, a `-`, or nothing after it. In `5EUR` or `10EB`, it is part of a word, so lowercasing it would not help.
			return 'An exponent marker is a lowercase “e”' if text.match?(/\A-?[0-9][0-9_]*(?:\.[0-9_]+)?E-?[0-9_]*\z/)
			return 'A decimal point must be followed by a digit' if text.match?(/\A-?[0-9_]+\.(?:\z|[^0-9_])/)
			return 'A number cannot begin with “.”; write a digit before it, as in -0.5' if text.start_with?('-.')

			if text.match?(/\A[0-9]+(?::[0-9]+)+\z/)
				return text.match?(/\A[0-9]{1,2}:[0-9]{2}(?::[0-9]{2}(?:\.[0-9]+)?)?\z/) ? 'A time of day is a string, so it must be quoted' : "Invalid number “#{abbreviate(text)}”. A value that contains “:” must be quoted, as in '#{abbreviate(text)}'"
			end

			# A value with a `:` that starts with a zero, such as the MAC address `00:1A:2B`, is not a number with a leading zero, because removing the zero would not make it valid.
			if text.match?(/\A-?0[0-9_]/) && !text.include?(':')
				# Removing the zero gives a valid number with a different meaning, so the message says what the zero usually meant.
				# A `'...'` string cannot hold a `'`, so then there is no example.
				identifier = "an identifier, such as a ZIP code, as a string#{unquoted_text.include?("'") ? '' : ": '#{abbreviate(unquoted_text)}'"}"

				# The octal suggestion is only for the number on its own, not for one that more text follows, as in `0412 345 678`, and only when it is in range. It is decided on the whole number, because a cut can end before a digit that is not octal or that changes the value.
				digits = full_text.lstrip('0')
				octal = "0o#{digits.empty? ? '0' : digits}"

				if unquoted_text == full_text && full_text.match?(/\A0[0-7]+\z/) && valid_value?(octal)
					return "Leading zeros are not allowed in a decimal number. Write an octal number, such as a file mode, as #{abbreviate(octal)}, and #{identifier}"
				end

				return text.match?(/\A0[0-9]+\z/) ? "Leading zeros are not allowed in a decimal number. Write #{identifier}" : 'Leading zeros are not allowed in a decimal number'
			end

			# Only in a number: an underscore next to a letter other than the exponent marker is part of a word, such as `4k_video`.
			return 'An underscore in a number must be between two digits' if text.match?(/_(?:\z|[^0-9])|(?:\A|[^0-9])_/) && !text.match?(/[^-0-9_.e]/)
			return 'Leading zeros are not allowed in an exponent' if text.match?(/\A-?[0-9][0-9_]*(?:\.[0-9_]+)?e-?0_?[0-9]/)
			return '“e-0” is not allowed, because an exponent of zero has one spelling: e0' if text.match?(/\A-?[0-9][0-9_]*(?:\.[0-9_]+)?e-0\z/)
			# Only a number ends with its exponent marker. A word that ends with an “e”, such as `1byte` or `-verbose`, has no exponent.
			return 'Expected digits after the exponent marker “e”' if text.match?(/\A-?[0-9][0-9_]*(?:\.[0-9_]+)?e-?\z/)
			return "Invalid number “#{abbreviate(text)}”. A value with several dots, such as a version number, must be quoted" if text.count('.') > 1

			if text.match?(/\A-(?:[^0-9]|\z)/)
				# The whole word, as for one without the “-”, so that a word such as `-nano` or `-info` is not taken for NaN or infinity.
				return 'NaN is not representable. Use null for a missing value' if text.match?(/\A-nan\z/i)

				return text.match?(/\A-inf(?:inity)?\z/i) ? "“#{abbreviate(text)}” is not a value. Negative infinity is written -infinity" : 'Expected a digit or “infinity” after “-”'
			end

			text.match?(/[A-Za-z]/) ? "Invalid number “#{abbreviate(text)}”. A string value must be quoted#{quoting_example(unquoted_text)}" : "Invalid number “#{abbreviate(text)}”"
		end

		# A date alone, which is not an instant. The instant it could be is only shown when the date exists, so that the example is valid.
		def describe_date(date)
			year, month, day = date.split('-').map(&:to_i)
			is_existing = year >= 1 && month.between?(1, 12) && day.between?(1, days_in_month(year, month))
			"#{date} is a date, not an instant. Write a date as a string, as in '#{date}'#{is_existing ? ". An instant needs a time and an offset, as in #{date}T00:00:00Z" : ''}"
		end

		# An offset on its own after spaces, as in `2026-09-19T14:00:00 Z`, which belongs directly after the time, or `nil`.
		def offset_after_space
			offset_start = skip_spaces(@index)
			return if offset_start == @index

			# The bytes, because the 6 of them can end inside a character, which a regex refuses to read. An offset is ASCII.
			offset = @source.byteslice(offset_start, 6).b[/\A(?:Z|[+-][0-9]{2}:[0-9]{2})/]
			offset if offset && value_end?(offset_start + offset.bytesize)
		end

		# `time` is the token after a space that follows `text`, or an empty string. `is_whole_value` is whether nothing that may be part of the instant follows `text`. `offset` is an offset after a space that follows `text`, or `nil`.
		def describe_bad_instant(text, time, is_whole_value, offset)
			generic = "Invalid instant “#{abbreviate(text)}”. #{INSTANT_FORMAT}"

			if text.bytesize > MAX_DIAGNOSED_LENGTH
				generic
			elsif text.match?(/\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/)
				time.match?(/\A[0-9]{2}:[0-9]{2}/) ? describe_space_separated_instant(text, time, is_whole_value) : describe_date(text)
			elsif text.match?(/\A[0-9]{4}-[0-9]{2}-[0-9]{2}t/)
				'The date and time separator in an instant is an uppercase “T”'
			elsif text.end_with?('z')
				'The UTC offset in an instant is an uppercase “Z”'
			elsif text.match?(/[+-][0-9]{4}\z/)
				"An instant's offset is written with a colon, as in +07:00"
			elsif !text.match?(LOCAL_DATE_TIME)
				generic
			elsif offset
				# The instant has the offset it was meant in, so it is not a local time to write as a string.
				reason = 'An instant\'s offset follows its time directly, without a space'
				valid_value?("#{text}#{offset}") ? "#{reason}, as in #{abbreviate("#{text}#{offset}")}" : reason
			elsif is_whole_value
				"An instant needs an offset: Z or ±HH:MM. A date and time without an offset is a local time, which is not an instant, so write it as a string, as in '#{abbreviate(text)}', or add the offset it was meant in"
			else
				'An instant needs an offset: Z or ±HH:MM'
			end
		end

		# A date and a time with a space between them, where an instant has a "T". Following the example must not turn a local time into UTC silently, so a time without an offset is described as what it is. An instant is only shown when it is valid, so a date that does not exist, a time out of range, or an instant outside the years 0001 to 9999 in UTC gets the general format instead.
		def describe_space_separated_instant(date, time, is_whole_value)
			separator = 'The date and time separator in an instant is an uppercase “T”, not a space'
			instant = "#{date}T#{time}"

			is_short = instant.bytesize <= MAX_DIAGNOSED_LENGTH

			if is_short && valid_value?(instant)
				"#{separator}, as in #{abbreviate(instant)}"
			elsif is_short && is_whole_value && instant.match?(LOCAL_DATE_TIME) && valid_value?("#{instant}Z")
				"#{separator}, and an instant needs the offset it was meant in, as in #{abbreviate(instant)}Z for UTC. A date and time without an offset is a local time, which is not an instant, so write it as a string, as in '#{abbreviate("#{date} #{time}")}'"
			else
				"#{separator}. #{INSTANT_FORMAT}"
			end
		end

		# Whether `text` is one valid value, so that an error message only suggests a fix that works.
		def valid_value?(text)
			Parser.new("[#{text}]").parse.length == 1
		rescue ParseError
			false
		end
	end
end
