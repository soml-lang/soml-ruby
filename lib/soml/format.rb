# frozen_string_literal: true

module SOML
	# The formatter. It is a close port of the JS reference's `format.ts`: it prints the {Tree} of a document with the layout of the specification's formatter, and copies every token and comment from the source, so the value and the spelling cannot change.
	#
	# @api private
	class Printer
		# The brackets of a container, by its type, so that writing one allocates no array for them.
		BRACKETS = Ractor.make_shareable({object: ['{', '}'], array: ['[', ']']})

		private_constant :BRACKETS

		# @param tree [Tree]
		def initialize(tree)
			@source = tree.source
			@body = tree.body
			@comments = tree.comments
			@output = +''
			@comment_index = 0
		end

		# @return [String] The formatted document, ending with one line feed.
		def print
			items = @body.type == :object && !@body.braced ? @body.members : [@body]

			# The document is a list without brackets: the members of a brace-less object, or one braced collection.
			write_list(items, 0, @source.bytesize, 0, false)
			@output << "\n"
		end

		private

		# Starts a new line at `level`, with one blank line before it when the source had one.
		def new_line(level, is_blank)
			# The first line of the file has no line break before it.
			return if @output.empty?

			@output << (is_blank ? "\n\n" : "\n") << INDENTS[level]
		end

		# The start of the line that `offset` is on, but never before `previous_end`, which is the start of the range when there is no line break in it.
		def line_start_of(offset, previous_end)
			index = offset
			index -= 1 while index > previous_end && @source.getbyte(index - 1) != 0x0A
			index
		end

		# Whether no line break comes between `start` and `finish`. The scan stops at `finish`.
		def same_line?(start, finish)
			index = start

			while index < finish
				return false if @source.getbyte(index) == 0x0A

				index += 1
			end

			true
		end

		# Whether a line between `start` and `finish` holds only spaces and tabs, if anything. The scan stops at `finish`.
		def blank_line_between?(start, finish)
			index = start

			while index < finish
				if @source.getbyte(index) == 0x0A
					following = index + 1
					following += 1 while following < finish && (@source.getbyte(following) == 0x20 || @source.getbyte(following) == 0x09)
					return true if following < finish && @source.getbyte(following) == 0x0A

					index = following
				else
					index += 1
				end
			end

			false
		end

		# The next comment that ends at or before `finish`, without consuming it.
		def peek_comment(finish)
			comment = @comments[@comment_index]
			comment if comment && comment.finish <= finish
		end

		def write_comment(comment)
			@comment_index += 1
			text = @source.byteslice(comment.start, comment.finish - comment.start)

			if comment.type == :line
				@output << trim_trailing_whitespace(text)
				return
			end

			# The lines of a block comment keep their own indentation. Trailing whitespace is removed, and runs of blank lines collapse to one, as everywhere outside a block string.
			lines = text.split("\n", -1).map { trim_trailing_whitespace(it) }

			# The first line starts with `/*`, so it is never empty.
			@output << lines.reject.with_index { |line, index| line.empty? && lines[index - 1].empty? }.join("\n")
		end

		# The offset of the `,` after an item in the source, or `nil` when there is none.
		def find_comma(start, finish)
			source = @source
			index = start

			# Between two items there is only whitespace, comments, and at most one comma.
			while index < finish
				# A comma inside a comment is not one. Each jump lands on the line feed after a line comment, or on the `/` of a block comment's end, and the loop steps past it.
				case source.getbyte(index)
				when 0x2C # ,
					return index
				when 0x23 # #
					index = source.byteindex("\n", index) || finish
				when 0x2F # /
					index = source.byteindex('*/', index + 2) + 1
				end

				index += 1
			end

			nil
		end

		# Writes `items` one per line at `level`, with the comments between them, from `start` to `finish` in the source.
		#
		# A comment on the line of the item before it, or of the opening bracket, stays at the end of that line. The exception is a block comment after the comma that the next item follows on the same line, as in `[1, /* note */ 2]`: it stays in front of that item. Every other comment starts a new line, and a comment or an item that follows a block comment on its line stays on that line.
		def write_list(items, start, finish, level, is_bracketed)
			previous_end = start
			item_end = nil
			# Whether a comment may stay at the end of the line before it, which needs an item or an opening bracket there.
			can_trail = is_bracketed
			# Whether the list has written something other than a comment at the end of the opening bracket's line. A blank line is kept only after that, so none is left directly inside the bracket or at the start of the file.
			has_written = false
			is_on_same_line = false

			# One more round than there are items, for the comments after the last one.
			0.upto(items.length) do |index|
				item = items[index]
				item_start = item ? item.start : finish
				comma = is_bracketed ? find_comma(previous_end, item_start) : nil

				# Found once per item rather than once per comment, which would be quadratic in the number of comments on one line.
				item_line_start = item && line_start_of(item_start, previous_end)

				while (comment = peek_comment(item_start))
					is_trailing = can_trail && !is_on_same_line && trailing?(comment, previous_end, item_end, item_line_start, comma)

					if is_trailing || is_on_same_line
						@output << ' '
					else
						new_line(level, has_written && blank_line_between?(previous_end, comment.start))
					end

					write_comment(comment)
					has_written ||= !is_trailing

					# A block comment that the next comment or item follows on the same line keeps it on that line.
					next_start = peek_comment(item_start)&.start || item_start
					is_on_same_line = comment.type == :block && !is_trailing && same_line?(comment.finish, next_start)
					previous_end = comment.finish
				end

				return if item.nil?

				if is_on_same_line
					@output << ' '
				else
					new_line(level, has_written && blank_line_between?(previous_end, item_start))
				end

				write_item(item, level)
				previous_end = item.finish
				item_end = previous_end
				can_trail = true
				has_written = true
				is_on_same_line = false
			end
		end

		# Writes a container that is on one line in the source on one line, with a comma and a space between its members or items and no trailing comma. Only a block comment can be inside it, and each one stays where it is among the items and commas.
		def write_one_line(items, start, finish, level, opening, closing)
			@output << opening
			previous_end = start + 1
			has_written_token = false

			0.upto(items.length) do |index|
				item = items[index]
				item_start = item ? item.start : finish - 1
				# The comma after the last item is left out.
				comma = item && find_comma(previous_end, item_start)
				has_written_comma = false

				while (comment = peek_comment(item_start))
					if !has_written_comma && comma && comma < comment.start
						@output << ','
						has_written_comma = true
					end

					@output << ' ' if has_written_token
					write_comment(comment)
					has_written_token = true
				end

				break if item.nil?

				if comma && !has_written_comma
					@output << ', '
				elsif has_written_token
					@output << ' '
				end

				write_item(item, level)
				previous_end = item.finish
				has_written_token = true
			end

			@output << closing
		end

		def write_item(item, level)
			if item.type == :member
				write_member(item, level)
			else
				write_value(item, level)
			end
		end

		# Whether a comment stays at the end of the line before it. That line ends at the item before it, or at the comma after that item.
		def trailing?(comment, previous_end, item_end, item_line_start, comma)
			is_after_comma = !comma.nil? && comment.start > comma

			# A block comment after the comma that the next item follows on the same line stays in front of that item. The comment ends on the item's line when it ends after the start of that line.
			return false if item_line_start && comment.type == :block && (comma.nil? || is_after_comma) && comment.finish >= item_line_start

			# A comment after the comma ends the comma's line, which is later than the item's when a block comment that spans lines comes between them. The comma is removed, so the comment moves to the end of the item's line, which only holds when nothing came between them.
			line_end = is_after_comma && previous_end == item_end ? comma + 1 : previous_end
			same_line?(line_end, comment.start)
		end

		def write_member(member, level)
			key = member.key
			value = member.value
			@output << @source.byteslice(key.start, key.finish - key.start) << ':'
			block_string = value.type == :scalar && value.block

			if peek_comment(value.start).nil?
				# A block string begins on the next line, one level deeper, so its delimiters and content line up.
				if block_string
					new_line(level + 1, false)
					write_value(value, level + 1)
					return
				end

				@output << ' '
				write_value(value, level)
				return
			end

			# With comments between the `:` and the value, the line breaks between them are kept, but not the blank lines, and a value on a new line is one level deeper.
			previous_end = key.finish + 1
			value_level = level

			while (comment = peek_comment(value.start))
				value_level = level + 1 if write_separator(previous_end, comment.start, level + 1)
				write_comment(comment)
				previous_end = comment.finish
			end

			if block_string
				new_line(level + 1, false)
				value_level = level + 1
			elsif write_separator(previous_end, value.start, level + 1)
				value_level = level + 1
			end

			write_value(value, value_level)
		end

		# A space when `finish` is on the line of `start` in the source, and otherwise a new line at `level`. Returns whether it started a new line.
		def write_separator(start, finish, level)
			if same_line?(start, finish)
				@output << ' '
				return false
			end

			new_line(level, false)
			true
		end

		def write_value(node, level)
			start = node.start
			finish = node.finish

			if node.type == :scalar
				text = @source.byteslice(start, finish - start)
				@output << (node.block ? reindent_block_string(text, INDENTS[level]) : text)
				return
			end

			opening, closing = BRACKETS[node.type]
			items = node.type == :object ? node.members : node.elements

			# Every comment before the container is already written, so a next comment that ends by `finish` is inside it. A container that holds only comments is not empty.
			if items.empty? && peek_comment(finish).nil?
				@output << opening << closing
				return
			end

			if same_line?(start, finish)
				write_one_line(items, start, finish, level, opening, closing)
				return
			end

			@output << opening
			write_list(items, start + 1, finish - 1, level + 1, true)
			new_line(level, false)
			@output << closing
		end

		# Only spaces and tabs are whitespace in SOML. Any other character, such as a no-break space, is content.
		def trim_trailing_whitespace(text)
			# A loop rather than a regex, which would keep a backtracking entry for every space of a long run.
			finish = text.bytesize
			finish -= 1 while finish.positive? && ((byte = text.getbyte(finish - 1)) == 0x20 || byte == 0x09)
			text.byteslice(0, finish)
		end

		# Moves a block string to a new indentation. Its content is relative to the closing delimiter's indentation, so replacing that indentation on every line keeps the value. A blank line is left as it is, because it becomes an empty line either way.
		def reindent_block_string(text, indentation)
			lines = text.split("\n", -1)
			closing = lines.last
			old_length = 0
			old_length += 1 while (byte = closing.getbyte(old_length)) == 0x20 || byte == 0x09

			lines.map.with_index do |line, index|
				index.zero? || !line.match?(NOT_BLANK_CHARACTER) ? line : indentation + line.byteslice(old_length, line.bytesize - old_length)
			end.join("\n")
		end
	end
end
