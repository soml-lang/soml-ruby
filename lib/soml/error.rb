# frozen_string_literal: true

module SOML
	# The base class of the errors this library raises.
	class Error < StandardError
		# Characters that a terminal acts on rather than shows: control characters other than tab, and bidirectional controls. They are replaced in an error message, so that printing it cannot run a terminal escape or reorder the text.
		UNPRINTABLE = /[\p{Bidi_Control}[\p{Cc}&&[^\t]]]/

		private_constant :UNPRINTABLE

		# `text` with the characters that a terminal acts on replaced, for every message that can show a value or a name from the caller.
		#
		# @api private
		# @param text [String]
		# @return [String]
		def self.sanitize(text) = text.gsub(UNPRINTABLE, "\uFFFD")
	end

	# Raised by {SOML.parse}, {SOML.load_file}, and {SOML::Duration.parse} when the input is not valid.
	#
	# The {#message} is the reason and the position, on one line, with the file when the document came from {SOML.load_file}. The {#detailed_message}, which Ruby shows for an uncaught error, adds a code frame.
	#
	# @example
	#   begin
	#     SOML.parse('name: api-gateway')
	#   rescue SOML::ParseError => error
	#     error.message
	#     #=> "Unexpected “api-gateway”. A string value must be quoted, as in 'api-gateway' at line 1, column 7"
	#     error.code_frame
	#     #=> "> 1 | name: api-gateway\n    |       ^"
	#   end
	class ParseError < Error
		CONTEXT_LINES = 2
		MAX_LINE_WIDTH = 100

		private_constant :CONTEXT_LINES, :MAX_LINE_WIDTH

		# @return [String] What is wrong, without the position.
		attr_reader :reason

		# @return [Integer] The 1-based line of the error.
		attr_reader :line

		# @return [Integer] The 1-based column of the error, counted in characters.
		attr_reader :column

		# @return [Integer] The 0-based character index of the error in the source read as UTF-8, so for a UTF-8 source, `source[error.offset]` is the character at the error.
		attr_reader :offset

		# @return [String, nil] The file the document is from, when it was read by {SOML.load_file}.
		attr_reader :path

		# @api private
		# @param reason [String]
		# @param source [String] The valid UTF-8 text before the error, at least.
		# @param byte_offset [Integer] Where the error is in `source`, in bytes.
		# @param path [String, nil] The file the source is from.
		def initialize(reason, source, byte_offset, path = nil)
			@reason = Error.sanitize(reason)

			# A copy, which shares the bytes, so that a caller that changes its string afterwards does not change the code frame.
			@source = source.dup
			before = source.byteslice(0, byte_offset)
			@offset = before.length
			@line = before.count("\n") + 1
			@line_start = (before.rindex("\n") || -1) + 1
			@column = @offset - @line_start + 1
			@path = path

			# A file position is written as editors and terminals read it.
			super(path ? "#{@reason} at #{show_path(path)}:#{@line}:#{@column}" : "#{@reason} at line #{@line}, column #{@column}")
		end

		# Up to three lines ending at the error, with a caret under the position. A long line is clipped around the position.
		#
		# @return [String]
		def code_frame
			# A frozen error, such as one made shareable for a ractor, cannot keep it.
			return create_code_frame if frozen?

			@code_frame ||= create_code_frame
		end

		# The message and the code frame, which Ruby shows for an uncaught error.
		#
		# @return [String]
		def detailed_message(highlight: false, **) = "#{super}\n\n#{code_frame}"

		private

		def create_code_frame
			# The error line and up to two lines before it, found by searching back from the error, so that an error late in a long document does not split the whole document.
			line_starts = [@line_start]

			while line_starts.length <= CONTEXT_LINES && line_starts.first.positive?
				# The line before starts after the line break before its own line break. A negative start would count from the end.
				search_from = line_starts.first - 2
				line_starts.unshift(search_from.negative? ? 0 : (@source.rindex("\n", search_from) || -1) + 1)
			end

			first_line = @line - line_starts.length + 1
			gutter_width = @line.to_s.length
			output = []

			line_starts.each.with_index(first_line) do |line_start, number|
				is_error_line = number == @line
				line_end = @source.index("\n", line_start) || @source.length
				text, pointer = clip(Error.sanitize(@source[line_start...line_end]), is_error_line ? @offset - line_start : 0)
				gutter = "#{is_error_line ? '>' : ' '} #{number.to_s.rjust(gutter_width)} |"
				output << (text.empty? ? gutter : "#{gutter} #{text}")

				next unless is_error_line

				# The tabs of the line are kept, so the caret lines up whatever the tab width is.
				padding = text[0, pointer].gsub(/[^\t]/, ' ')
				output << "  #{' ' * gutter_width} | #{padding}^"
			end

			output.join("\n")
		end

		# A long line, such as a minified document, is cut to a window around the pointer.
		def clip(text, pointer)
			return [text, pointer] if text.length <= MAX_LINE_WIDTH

			start = (pointer - (MAX_LINE_WIDTH / 2)).clamp(0, text.length - MAX_LINE_WIDTH)
			finish = start + MAX_LINE_WIDTH
			prefix = start.positive? ? '…' : ''
			suffix = finish < text.length ? '…' : ''
			["#{prefix}#{text[start...finish]}#{suffix}", pointer - start + prefix.length]
		end

		# The path in UTF-8, so that it joins the reason, with what is not printable replaced, as in the reason.
		def show_path(path)
			Error.sanitize(Parser.lossy_utf8(path))
		end
	end

	# Raised by {SOML.generate} for a value that cannot be written.
	#
	# @example
	#   begin
	#     SOML.generate({servers: [{ratio: Float::NAN}]})
	#   rescue SOML::GenerateError => error
	#     error.message
	#     #=> "NaN is not representable. Use nil for a missing value (at servers[0].ratio)"
	#     error.path
	#     #=> ["servers", 0, "ratio"]
	#   end
	class GenerateError < Error
		# The message as it was given, which `to_s` adds the path to. So a copy made with another message, as by `raise error, 'Other'`, has that message as its reason and keeps the path.
		#
		# @!method reason
		#   @return [String] What is wrong, without the location.
		alias_method :reason, :to_s

		# @return [Array<String, Integer>] The keys and indexes that lead to the value, or an empty array for the top-level value.
		attr_reader :path

		# @api private
		def initialize(reason)
			@path = []

			# The reason may name a class or show a value, as in `Cannot generate a Foo`, which can hold anything, so it is sanitized as the reason of a `ParseError` is.
			super(Error.sanitize(reason))
		end

		# A copy, as made by `raise error, 'Other'`, has its own path, so that adding to the path of one does not change the other.
		def initialize_copy(other)
			super
			@path = @path.dup
		end

		# @return [String] The reason, and the path to the value when it is not the top-level value.
		def to_s
			return reason if @path.empty?

			"#{reason} (at #{Parser.describe_path(@path)})"
		end
	end
end
