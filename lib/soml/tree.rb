# frozen_string_literal: true

module SOML
	# A read-only syntax tree, returned by {SOML.parse_tree} and used by {SOML.format} and {SOML.edit}.
	#
	# Every offset is a byte offset into the UTF-8 source, and `finish` is the offset after the node. Use {#position} for line and column. The document is checked by {Parser} first, so the builder can assume valid input. A tree from {SOML.parse_tree} is deeply frozen. Node constructors are internal. Tokens keep the source text of keys, scalar values, and punctuation, and comments are listed separately, in source order.
	class Tree
		# The nodes are structs rather than `Data`, whose `new` builds a hash of keywords for every node, which made building a tree several times as slow as parsing the document. Nothing changes a node once it is made.

		# A `# ...` comment (`:line`) or a `/* ... */` comment (`:block`). `value` is its text without the delimiters.
		Comment = Struct.new(:type, :start, :finish, :value)

		# A lexical token with its original source text in `value`. `type` is `:punctuator`, `:bare_key`, `:string`, `:integer`, `:float`, `:keyword`, `:instant`, or `:duration`. Quoted keys are strings; booleans and null are keywords. Comments and whitespace are excluded.
		Token = Struct.new(:type, :start, :finish, :value)

		# An object, written with braces or, only at the top level, without them.
		ObjectNode = Struct.new(:members, :braced, :start, :finish) do
			def type = :object
		end

		ArrayNode = Struct.new(:elements, :start, :finish) do
			def type = :array
		end

		# A `key: value` member.
		MemberNode = Struct.new(:key, :value, :start, :finish) do
			def type = :member
		end

		# A key, with its decoded string `value` and `style` of `:bare`, `:literal`, or `:escaped`.
		KeyNode = Struct.new(:value, :start, :finish, :style) do
			def type = :key
		end

		# A value that is not a collection. `kind` is `:string`, `:integer`, `:float`, `:boolean`, `:null`, `:instant`, or `:duration`, and `value` is decoded as by SOML.parse. `block` is whether it is a block string. Strings have `style: :literal` or `:escaped`; integers have `radix: 2`, `8`, `10`, or `16`. In other kinds, `style` and `radix` are nil and `block` is false.
		ScalarNode = Struct.new(:block, :start, :finish, :kind, :value, :style, :radix) do
			def type = :scalar
		end

		# The characters that end the search for the closing quote of a `"..."` string.
		ESCAPED_STRING_SPECIAL = /["\\]/

		# The radix of an integer by the letter of its prefix, after its `0`.
		RADIX_PREFIXES = {0x62 => 2, 0x6F => 8, 0x78 => 16}.freeze

		# The distance in bytes between two of the character counts that {#position} starts from.
		CHECKPOINT_BYTES = 1024

		private_constant :ESCAPED_STRING_SPECIAL, :RADIX_PREFIXES, :CHECKPOINT_BYTES

		# @return [String] The source, in UTF-8.
		attr_reader :source

		# @return [ObjectNode, ArrayNode] The document's collection.
		attr_reader :body

		# @return [Array<Comment>] Every comment, in source order.
		attr_reader :comments

		# @return [Array<Token>] Every lexical token, in source order, with exclusive UTF-8 byte spans. Comments are in {#comments}.
		attr_reader :tokens

		# @param source [String] The document, decoded as {SOML.parse} decodes it.
		# @param lean [Boolean] Internal, for {SOML.format} and {SOML.edit}: whether to leave out the tokens and the line index, and not freeze the tree, because they read neither, and the tokens and the deep freeze each cost about as much as building the nodes. A lean tree has no {#tokens}, no comment text, and no {#position}.
		# @raise [ParseError] When the document is not valid, the same as {SOML.parse}.
		def initialize(source, lean: false)
			# Validates the whole document, so the builder below can assume valid input.
			parser = Parser.new(source)
			value = parser.parse
			@source = parser.source.dup.freeze
			@length = @source.bytesize
			@index = 0
			@comments = []
			@tokens = lean ? nil : []

			skip_trivia

			@body = case @source.getbyte(@index)
			when 0x7B # {
				parse_object(value)
			when 0x5B # [
				parse_array(value)
			else
				parse_bare_object(value)
			end

			skip_trivia
			return if lean

			# The start of each line, so that {#position} finds the line of an offset with a binary search, rather than by counting the line breaks before it, which is quadratic for a linter that asks for the position of every node.
			@line_starts = [0]
			line_break = -1
			@line_starts << line_break + 1 while (line_break = @source.byteindex("\n", line_break + 1))

			# The number of characters before every `CHECKPOINT_BYTES`th byte, so that {#position} counts the characters before an offset from the nearest one, rather than from the start of its line, which is quadratic for a linter on a long line. In an ASCII source, every character is one byte.
			unless @source.ascii_only?
				count = 0

				@checkpoints = 0.step(@length, CHECKPOINT_BYTES).map do |offset|
					before = count
					count += character_count(offset, CHECKPOINT_BYTES)
					before
				end
			end

			# Only the builder reads it.
			remove_instance_variable(:@index)

			Ractor.make_shareable(self)
		end

		# Yield the body and all its descendants in source order, each node before its children and each member's key before its value. Comments are available separately through {#comments}.
		#
		# @return [Enumerator] When no block is given.
		def each_node
			return enum_for(__method__) unless block_given?

			pending = [@body]

			until pending.empty?
				node = pending.pop
				yield node

				case node.type
				when :object
					node.members.reverse_each { pending << it }
				when :array
					node.elements.reverse_each { pending << it }
				when :member
					pending.push(node.value, node.key)
				end
			end

			self
		end

		# The 1-based line and column of a byte offset in {#source}. Columns count Unicode characters, not bytes or display cells. EOF is accepted. Unlike tree spans, {ParseError#offset} counts characters.
		#
		# @param byte_offset [Integer] An offset at a UTF-8 character boundary.
		# @return [Array<Integer>] The line and column.
		# @raise [TypeError] When the offset is not an integer.
		# @raise [ArgumentError] When the offset is out of bounds or inside a character.
		def position(byte_offset)
			raise TypeError, 'The byte offset must be an integer' unless Integer === byte_offset
			raise ArgumentError, 'The byte offset must be within the source' unless byte_offset.between?(0, @length)

			byte = @source.getbyte(byte_offset)
			raise ArgumentError, 'The byte offset must be at a character boundary' if byte&.between?(0x80, 0xBF)

			# The number of lines that start at or before the offset is its line.
			line = @line_starts.bsearch_index { it > byte_offset } || @line_starts.length
			line_start = @line_starts[line - 1]
			[line, character_index(byte_offset) - character_index(line_start) + 1]
		end

		private

		# The number of characters before `offset`, which is at a character boundary.
		def character_index(offset)
			return offset unless @checkpoints

			checkpoint, rest = offset.divmod(CHECKPOINT_BYTES)
			@checkpoints[checkpoint] + character_count(offset - rest, rest)
		end

		# The number of characters that start in the `length` bytes from `start`: the bytes that are not UTF-8 continuation bytes. The bytes may begin or end inside a character.
		def character_count(start, length)
			bytes = @source.byteslice(start, length).b
			# Note: Not using a complement count because it offers no measured speedup.
			bytes.bytesize - bytes.count("\x80-\xBF".b)
		end

		def skip_trivia
			source = @source
			index = @index

			# A lean tree, which has no tokens, has no comment text either, because {SOML.format} and {SOML.edit} copy comments from the source.
			while (byte = source.getbyte(index))
				case byte
				when 0x20, 0x09, 0x0A
					index += 1
				when 0x23 # #
					finish = source.byteindex("\n", index) || @length
					@comments << Comment.new(:line, index, finish, @tokens && source.byteslice(index + 1, finish - index - 1))
					index = finish
				when 0x2F # /
					# The parser checked that every block comment ends, so the search finds its `*/`.
					finish = source.byteindex('*/', index + 2) + 2
					@comments << Comment.new(:block, index, finish, @tokens && source.byteslice(index + 2, finish - index - 4))
					index = finish
				else
					break
				end
			end

			@index = index
		end

		# The decoded collection supplies each value in source order. A block with two parameters reads a member of a hash without the array of its key and value that a block with one would get.
		def parse_bare_object(value)
			members = value.map do |name, decoded|
				member = parse_member(name, decoded)
				skip_trivia
				member
			end

			ObjectNode.new(members, false, members.first.start, members.last.finish)
		end

		def parse_object(value)
			start = @index
			members = parse_items { value.map { |name, decoded| parse_item(parse_member(name, decoded)) } }
			ObjectNode.new(members, true, start, @index)
		end

		def parse_array(value)
			start = @index
			elements = parse_items { value.map { parse_item(parse_value(it)) } }
			ArrayNode.new(elements, start, @index)
		end

		# The items between an opening and a closing bracket, which are consumed too, from the block, which reads each with `parse_item`. The parser has already checked the separators, including that a comma is on the line of the item before it.
		def parse_items
			parse_punctuator
			skip_trivia
			items = yield
			parse_punctuator
			items
		end

		# Consumes the trivia and the comma after `item`, and returns it.
		def parse_item(item)
			skip_trivia

			if @source.getbyte(@index) == 0x2C # ,
				parse_punctuator
				skip_trivia
			end

			item
		end

		def parse_member(name, decoded)
			key = parse_key(name)
			parse_punctuator # :
			skip_trivia
			value = parse_value(decoded)
			MemberNode.new(key, value, key.start, value.finish)
		end

		def parse_key(value)
			source = @source
			start = @index
			byte = source.getbyte(start)

			if byte == 0x27 || byte == 0x22 # ' "
				finish = string_end(start)
				style = byte == 0x22 ? :escaped : :literal
			else
				finish = start
				finish += 1 while (byte = source.getbyte(finish)) && BARE_KEY_BYTE[byte]
				style = :bare
			end

			# Keys are decoded by the parser itself, so that the tree and `SOML.parse` cannot disagree.
			@index = finish
			add_token(style == :bare ? :bare_key : :string, start, finish)
			KeyNode.new(value, start, finish, style)
		end

		def parse_value(value)
			source = @source
			start = @index

			case (byte = source.getbyte(start))
			when 0x7B # {
				parse_object(value)
			when 0x5B # [
				parse_array(value)
			when 0x27, 0x22 # ' "
				return parse_block_string(byte, value) if source.getbyte(start + 1) == byte && source.getbyte(start + 2) == byte

				@index = string_end(start)
				scalar_node(value, false, start, @index)
			else
				finish = start + 1
				finish += 1 while (byte = source.getbyte(finish)) && NUMBER_BYTE[byte]
				@index = finish
				scalar_node(value, false, start, finish)
			end
		end

		# The offset after the closing quote of the one-line string at `start`. `'...'` ends at the next `'`. `"..."` ends at the next `"` that is not escaped, and `\` always starts a two-character escape or a `\u{…}`, which holds no quote.
		def string_end(start)
			source = @source
			return source.byteindex("'", start + 1) + 1 if source.getbyte(start) == 0x27

			index = start + 1

			loop do
				index = source.byteindex(ESCAPED_STRING_SPECIAL, index)
				return index + 1 if source.getbyte(index) == 0x22

				index += 2
			end
		end

		# The block ends at the first line whose first non-whitespace content is a run of exactly as many quotes as the opening delimiter.
		def parse_block_string(quote, value)
			source = @source
			start = @index
			delimiter_length = 0
			delimiter_length += 1 while source.getbyte(start + delimiter_length) == quote
			line_start = source.byteindex("\n", start) + 1

			loop do
				delimiter_start = line_start
				delimiter_start += 1 while (byte = source.getbyte(delimiter_start)) == 0x20 || byte == 0x09
				run_length = 0
				run_length += 1 while source.getbyte(delimiter_start + run_length) == quote

				if run_length == delimiter_length
					@index = delimiter_start + delimiter_length
					return scalar_node(value, true, start, @index)
				end

				line_start = source.byteindex("\n", line_start) + 1
			end
		end

		# Consume one bracket, colon, or comma that the parser has already validated.
		def parse_punctuator
			add_token(:punctuator, @index, @index + 1)
			@index += 1
		end

		# Record a token while scanning, so punctuation inside strings and comments never becomes a separate token. A lean tree has none.
		def add_token(type, start, finish)
			@tokens&.push(Token.new(type, start, finish, @source.byteslice(start, finish - start)))
		end

		# The value of the scalar from `start` to `finish`, already read by the parser as part of the document, with the spelling metadata that a lint rule needs.
		def scalar_node(value, block, start, finish)
			style = nil
			radix = nil

			kind = case value
			when String
				style = @source.getbyte(start) == 0x27 ? :literal : :escaped
				:string
			when Integer
				# A radix integer has no sign, so its prefix is at the start.
				radix = @source.getbyte(start) == 0x30 ? RADIX_PREFIXES.fetch(@source.getbyte(start + 1), 10) : 10
				:integer
			when Float
				:float
			when true, false
				:boolean
			when nil
				:null
			when Time
				:instant
			when Duration
				:duration
			end

			add_token(kind == :boolean || kind == :null ? :keyword : kind, start, finish)
			ScalarNode.new(block, start, finish, kind, value, style, radix)
		end
	end
end
