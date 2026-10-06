# frozen_string_literal: true

module SOML
	# The editor behind {SOML.edit}. It is a close port of the JS reference's `edit.ts`: it finds the value at a path in the {Tree} of a document, and makes the change as replacements of parts of the source, so everything else keeps its text.
	#
	# @api private
	class Editor
		# What removing a member or an item takes out of the source. `is_whole_lines` is whether it takes whole lines, which may leave a blank line next to another one.
		Removal = Struct.new(:start, :finish, :is_whole_lines)

		Replacement = Data.define(:start, :finish, :text)

		private_constant :Removal, :Replacement

		# @param source [String] The document.
		# @param path [Array<String, Symbol, Integer>, Tree::MemberNode, Tree::ObjectNode, Tree::ArrayNode, Tree::ScalarNode]
		# @param value [Object] The new value, unless `delete` is true.
		# @param delete [Boolean] Whether to remove the value instead.
		def initialize(source, path, value, delete:)
			case path
			when Tree::MemberNode, Tree::ObjectNode, Tree::ArrayNode, Tree::ScalarNode
				tree = Tree.new(source, lean: true)
				path = node_path(tree.body, path)
				raise ArgumentError, 'The node must be a member or a non-root value from the same source' unless path
			end

			# `Array#all?` on something else than an array, such as a hash, would read it in another way.
			unless Array === path && !path.empty? && path.all? { |segment| (Integer === segment && !segment.negative?) || String === segment || Symbol === segment }
				raise TypeError, 'The path must be a non-empty array of keys and array indexes, or a member or value node from SOML.parse_tree'
			end

			# A key is checked as `generate` checks one, and read as the UTF-8 string it names, so that a symbol finds its string. A key of a removal is not written, so a carriage return in it is no error: it finds nothing.
			generator = Generator.new
			names = []

			path.each do |segment|
				names << (Integer === segment ? segment : generator.member_name(segment, written: !delete))
			rescue GenerateError => error
				# A key that cannot be written is reported at the place of the object that holds it, as `generate` reports one.
				error.path.unshift(*names)
				raise
			end

			@path = names.freeze
			@value = value
			@delete = delete

			tree ||= Tree.new(source, lean: true)
			@source = tree.source
			# The same bytes, for the searches for a line break from an offset that may be inside a character, such as the last byte of a line that ends with `é`, which `String#byterindex` refuses in UTF-8.
			@bytes = @source.b
			@length = @source.bytesize
			@body = tree.body
			@comments = tree.comments
			@replacements = []
			# Whether the container being edited is inside one that stays on one line, so that it stays on one line too. An edit follows one path, so one flag is enough.
			@is_inside_one_line = false

			# The end of each comment, by its start, so that the trivia between tokens can be skipped.
			@comment_ends = @comments.to_h { [it.start, it.finish] }
			# The start of each block comment, by its end, so that the comments before a member or an item can be found.
			@block_comment_starts = @comments.filter_map { [it.finish, it.start] if it.type == :block }.to_h
		end

		# @return [String] The changed document.
		def edit
			descend(@body, 0, 1)

			# Replacements never overlap. A stable sort keeps the creation order of two insertions at the same offset.
			result = +''
			position = 0

			@replacements.sort_by.with_index { |replacement, index| [replacement.start, index] }.each do |replacement|
				result << @source.byteslice(position, replacement.start - position)
				result << replacement.text
				position = replacement.finish
			end

			result << @source.byteslice(position, @length - position)

			# The result is checked, so that a mistake here raises rather than writing a broken document.
			begin
				Parser.new(result).parse
			rescue ParseError
				raise "SOML.edit made an invalid document for the path #{describe_path(@path)}. This is a bug in soml-lang"
			end

			result
		end

		private

		# Resolve a parsed node to the path that the editor follows, or `nil` when it is not a member or a non-root value of `body`. Matching complete nodes also rejects mismatched spans or values; callers must still use the same source. The search goes down through the one member or item whose span holds the node, so it reads one of them at each level.
		def node_path(body, target)
			path = []
			container = body

			while container.type == :object || container.type == :array
				is_object = container.type == :object
				items = is_object ? container.members : container.elements
				index = items.bsearch_index { it.finish > target.start }
				item = index && items[index]
				return if item.nil? || item.start > target.start

				path << (is_object ? item.key.value : index)
				return path if item == target || (is_object && item.value == target)

				container = is_object ? item.value : item
			end
		end

		def edit_in_array(array, index, depth)
			position = @path[index]
			raise TypeError, "Cannot edit #{describe_path(@path)}, because #{describe_parent(index)} is an array, so it needs an index, not a key" unless Integer === position

			elements = array.elements

			# An index past the end, which may be too large for `Array#[]`.
			if position >= elements.length
				# Removing an item that is not there changes nothing, at the end of the array or past it, and so does removing something below it.
				return if @delete

				count = elements.length

				if position != count
					items = count == 1 ? '1 item' : "#{count} items"
					owner = index.zero? ? 'the document' : "the array at #{describe_parent(index)}"
					raise IndexError, "Cannot edit #{describe_path(@path)}, because #{owner} has #{items}. Add an item at index #{count}"
				end

				new_value = nest(index + 1)
				insert(array, elements.last) { |indentation| value_text(new_value, index + 1, depth + 1, indentation, array) }
				return
			end

			element = elements[position]

			if index < @path.length - 1
				@is_inside_one_line = one_line?(array)
				descend(element, index + 1, depth + 1)
			elsif @delete
				remove_node(array, element)
			else
				replace(element, depth + 1, array)
			end
		end

		def edit_in_object(object, index, depth)
			key = @path[index]
			raise TypeError, "Cannot edit #{describe_path(@path)}, because #{describe_parent(index)} is an object, so it needs a key, not an index" unless String === key

			member = object.members.find { it.key.value == key }

			if member
				if index < @path.length - 1
					@is_inside_one_line = one_line?(object)
					descend(member.value, index + 1, depth + 1)
				elsif @delete
					remove_member(object, member)
				else
					replace_member_value(member, depth + 1, object)
				end

				return
			end

			return if @delete

			written_key = Generator.format_key(key)
			new_value = nest(index + 1)
			insert(object, object.members.last) { |indentation| "#{written_key}: #{value_text(new_value, index + 1, depth + 1, indentation, object)}" }
		end

		# Edits the path from `index` on, inside `node`, whose own depth is `depth`.
		def descend(node, index, depth)
			case node.type
			when :array
				edit_in_array(node, index, depth)
			when :object
				edit_in_object(node, index, depth)
			else
				raise TypeError, "Cannot edit #{describe_path(@path)}, because #{describe_parent(index)} is not an object or an array"
			end
		end

		def replace(node, depth, container)
			@replacements << Replacement.new(node.start, node.finish, value_text(@value, @path.length, depth, indentation(node.start), container))
		end

		# Replaces the value of `member`. A block string begins on the line after its key, and the new value is never a block string, so when only whitespace comes between the `:` and a block string, the new value goes on the key's line, as the formatter writes it.
		def replace_member_value(member, depth, object)
			value = member.value
			colon_end = member.key.finish + 1

			unless value.type == :scalar && value.block && skip_whitespace(colon_end) == value.start
				replace(value, depth, object)
				return
			end

			@replacements << Replacement.new(colon_end, value.finish, " #{value_text(@value, @path.length, depth, indentation(member.start), object)}")
		end

		# Removes `member`. Removing the only member of a document without braces leaves `{}` in its place, because a document is never empty, and the comments that the member owned stay.
		def remove_member(object, member)
			if object.braced || object.members.length > 1
				remove_node(object, member)
				return
			end

			@replacements << Replacement.new(member.start, member.finish, '{}')
		end

		# Removes `node` from `container`.
		#
		# The removal also takes a blank line that would be left next to another one or directly inside a bracket. When the only item of a braced container goes and no comment is left inside, its brackets close up, as `[]`.
		def remove_node(container, node)
			items = container.type == :array ? container.elements : container.members
			# When the removed item is the last one and has no comma after it, it takes the comma before it, so that no trailing comma is left, as `[1, 2]` becomes `[1]`.
			takes_comma_before = node.equal?(items.last) && @source.getbyte(skip_trivia(node.finish)) != 0x2C
			removal = node_removal(node, takes_comma_before)
			take_blank_line(removal, container) if removal.is_whole_lines

			if items.length == 1 && braced?(container) && !comment_left?(container, removal)
				@replacements << Replacement.new(container.start + 1, container.finish - 1, '')
				return
			end

			@replacements << Replacement.new(removal.start, removal.finish, '')
		end

		# Whether a comment inside `container` is outside `removal`.
		def comment_left?(container, removal)
			@comments.any? do |comment|
				comment_start = comment.start
				comment_start > container.start && comment_start < container.finish && (comment_start < removal.start || comment_start >= removal.finish)
			end
		end

		# What removing a member or an item, with the comments it owns and its comma, takes out of the source. With `takes_comma_before`, a comma directly before it goes too.
		def node_removal(node, takes_comma_before)
			start = owned_start(node.start)
			finish = owned_end(node.finish)
			following = skip_spaces(finish)
			# Only a braced container can have commas.
			has_comma = @source.getbyte(following) == 0x2C

			# The comma before it is only taken when spaces alone are between them and the comments it owns. The scan back only crosses spaces, so it stays short on a long line.
			before = skip_spaces_back(start)
			removal_start = takes_comma_before && before.positive? && @source.getbyte(before - 1) == 0x2C ? before - 1 : start
			# The comments after its comma go with it when they end its line, as the formatter keeps them after it.
			result = removal(removal_start, has_comma ? line_end_after_trivia(following + 1) || following + 1 : finish)

			# When it takes the comma before it, the spaces before a comment after it stay, so that the comment does not join the item before the comma.
			if removal_start != start && !result.is_whole_lines && @comment_ends.key?(result.finish)
				result.finish = skip_spaces_back(result.finish)
			end

			result
		end

		# The start of the block comments that a member or an item at `offset` owns before it: those on its line after the comma or the opening bracket before it, as `/* note */` in `[1, /* note */ 2]`. The formatter keeps them in front of it. It is `offset` when there are none.
		def owned_start(offset)
			while (comment_start = @block_comment_starts[skip_spaces_back(offset)])
				offset = comment_start
			end

			offset
		end

		# The end of the comments that a member or an item ending at `offset` owns after it: those on its line before its comma or the closing bracket, as `/* note */` in `[1 /* note */, 2]` and `[1, 2 /* note */]`, and a line comment at the end of its line. The formatter keeps them after it. It is `offset` when there are none.
		def owned_end(offset)
			while (comment_end = @comment_ends[skip_spaces(offset)])
				offset = comment_end
			end

			offset
		end

		# The removal of the text from `start` to `finish`. When nothing else is on its lines, it takes the lines, including a comment at the end of the last one.
		def removal(start, finish)
			line_end = line_end_after_trivia(finish)

			# The line start is only looked for when nothing follows on the line, because the scan back to it is long for an item in the middle of a long line, and doing it for every item would be quadratic.
			if line_end
				line_start = line_start(start)
				return Removal.new(line_start, [line_end + 1, @length].min, true) if skip_spaces(line_start) == start
			end

			# The spaces after the text go too, and the spaces before it when nothing follows it on the line or in its container.
			after = skip_spaces(finish)
			byte = @source.getbyte(after)
			is_last = byte.nil? || byte == 0x0A || byte == 0x7D || byte == 0x5D
			Removal.new(is_last ? skip_spaces_back(start) : start, after, false)
		end

		# Widens a removal of whole lines by a blank line that would otherwise be left next to another blank line, or directly inside a bracket.
		def take_blank_line(removal, container)
			is_blank_before = removal.start.positive? && blank_line?(line_start(removal.start - 1))
			is_blank_after = removal.finish < @length && blank_line?(removal.finish)

			if is_blank_before && (is_blank_after || at_closing?(removal.finish, container))
				removal.start = line_start(removal.start - 1)
			elsif is_blank_after && removal.start == content_start(container)
				# The line is blank, so its line break follows its spaces.
				removal.finish = skip_spaces(removal.finish) + 1
			end
		end

		# The offset after the blank lines that start at `offset`.
		def skip_blank_lines(offset)
			offset = skip_spaces(offset) + 1 while blank_line?(offset)
			offset
		end

		# Whether only blank lines come between the line at `offset` and the line that closes `container`, or the end of the source.
		def at_closing?(offset, container)
			offset = skip_blank_lines(offset)
			offset == @length || (braced?(container) && skip_spaces(offset) == container.finish - 1)
		end

		# The start of the first line that is not blank after the line that opens `container`, or after the start of the source. The line that opens a container ends after the comments that follow its bracket, and when an item follows on it, this is `nil`.
		def content_start(container)
			return skip_blank_lines(0) unless braced?(container)

			line_end = line_end_after_trivia(container.start + 1)
			line_end && skip_blank_lines(line_end + 1)
		end

		def blank_line?(line_start) = @source.getbyte(skip_spaces(line_start)) == 0x0A

		def line_start(offset)
			return 0 if offset.zero?

			(@bytes.byterindex("\n", offset - 1) || -1) + 1
		end

		# Adds an item after `previous`, or into the empty `container` when there is none. The block gets the indentation of the item's line, and returns the item.
		#
		# An item on its own line needs no comma, so only an item added on the line of the item before it gets one, as in a one-line container.
		def insert(container, previous)
			if previous.nil?
				closing = container.finish - 1

				# A container that stays on one line keeps the item on that line, so `[/* note */]` becomes `[/* note */ 1]`, and `[1, []]` becomes `[1, [2]]`.
				if one_line?(container)
					start = skip_spaces_back(closing)
					@replacements << Replacement.new(start, closing, "#{start > container.start + 1 ? ' ' : ''}#{yield ''}")
					return
				end

				outer = indentation(container.start)
				inner = "#{outer}\t"
				line_start = line_start(closing)

				# A closing bracket on its own line keeps that line, and the item goes on a line before it.
				@replacements << if line_start > container.start && skip_spaces(line_start) == closing
					Replacement.new(line_start, line_start, "#{inner}#{yield inner}\n")
				else
					Replacement.new(skip_spaces_back(closing), closing, "\n#{inner}#{yield inner}\n#{outer}")
				end

				return
			end

			# The new item goes after the comments that the one before it owns, so that they stay with that one.
			previous_end = owned_end(previous.finish)
			following = skip_trivia(previous_end)
			has_comma = @source.getbyte(following) == 0x2C
			after_comma = has_comma ? following + 1 : previous_end
			line_end = line_end_after_trivia(after_comma)

			# Something follows on the same line, such as the closing bracket of a one-line object, so the item goes on that line too, and takes its indentation.
			if line_end.nil?
				item = yield indentation(after_comma)
				@replacements << (has_comma ? Replacement.new(after_comma, after_comma, " #{item},") : Replacement.new(previous_end, previous_end, ", #{item}"))
				return
			end

			indentation = indentation(previous.start)
			@replacements << Replacement.new(line_end, line_end, "\n#{indentation}#{yield indentation}")
		end

		# Whether `container` stays on one line: its brackets are on one line and something is between them, which {SOML.format} keeps, or it is inside a container that stays on one line. An empty `[]` or `{}` on its own gets its new item on a line of its own.
		def one_line?(container)
			return true if @is_inside_one_line

			start = container.start
			finish = container.finish
			braced?(container) && skip_spaces(start + 1) < finish - 1 && !@source.byteslice(start, finish - start).include?("\n")
		end

		# `value` as {SOML.generate} writes it, written inside `container` where the value at the first `path_length` segments of the path goes, as a container of depth `depth` whose lines after the first are indented by `indentation`. In a container on one line, the value is on one line too.
		def value_text(value, path_length, depth, indentation, container)
			text = Generator.new(one_line: one_line?(container)).generate_value(value, depth)

			# Every line break that {Generator} writes is between two lines of a container, because a string writes its line feeds as `\n`.
			indentation.empty? ? text : text.gsub("\n", "\n#{indentation}")
		rescue GenerateError => error
			# The error names the value's place in the document, as `generate` would name it in the whole document.
			error.path.unshift(*@path.first(path_length))
			raise
		end

		# The spaces and tabs at the start of the line that holds `offset`.
		def indentation(offset)
			line_start = line_start(offset)

			# A line that a block comment from an earlier line runs into, as in `/* a\n b */ x: 1`, is indented as the line where that comment starts.
			while (comment = comment_across(line_start))
				line_start = line_start(comment.start)
			end

			@source.byteslice(line_start, skip_spaces(line_start) - line_start)
		end

		# The comment that starts before `offset` and ends after it, if any. The comments are in source order, so a binary search finds the last one that starts before `offset`.
		def comment_across(offset)
			index = @comments.bsearch_index { it.start >= offset } || @comments.length
			comment = index.positive? ? @comments[index - 1] : nil
			comment if comment && comment.finish > offset
		end

		# Skips whitespace, line breaks, and comments.
		def skip_trivia(offset)
			offset = skip_line_trivia(offset)
			offset = skip_line_trivia(offset + 1) while @source.getbyte(offset) == 0x0A
			offset
		end

		# Skips spaces, tabs, and comments, but not a line break outside a comment.
		def skip_line_trivia(offset)
			loop do
				offset = skip_spaces(offset)
				comment_end = @comment_ends[offset]
				return offset if comment_end.nil?

				offset = comment_end
			end
		end

		# The offset of the line break that ends the line at `offset`, or the end of the source, when only whitespace and comments come before it. Otherwise `nil`.
		def line_end_after_trivia(offset)
			offset = skip_line_trivia(offset)
			offset if offset == @length || @source.getbyte(offset) == 0x0A
		end

		# Skips spaces, tabs, and line feeds, but not comments.
		def skip_whitespace(offset)
			offset += 1 while space?(byte = @source.getbyte(offset)) || byte == 0x0A
			offset
		end

		def skip_spaces(offset)
			offset += 1 while space?(@source.getbyte(offset))
			offset
		end

		def skip_spaces_back(offset)
			offset -= 1 while offset.positive? && space?(@source.getbyte(offset - 1))
			offset
		end

		def space?(byte) = byte == 0x20 || byte == 0x09

		def braced?(container) = container.type == :array || container.braced

		# `@value` inside new objects for the keys of the path from `index` on. An index there names an item of an array that does not exist yet, so it raises an `IndexError`.
		def nest(index)
			nested = @value

			(@path.length - 1).downto(index) do |position|
				segment = @path[position]
				raise IndexError, "Cannot edit #{describe_path(@path)}, because #{describe_parent(position)} does not exist, so it has no index #{segment}" if Integer === segment

				nested = {segment => nested}
			end

			nested
		end

		# The path comes from the caller, perhaps from user input, so it is cut short, and the characters that are invisible or that a terminal acts on become escapes.
		def describe_path(path) = Parser.describe_path(path)

		# The value that holds `@path[index]`.
		def describe_parent(index) = index.zero? ? 'the document' : describe_path(@path.first(index))
	end
end
