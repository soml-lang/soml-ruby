# frozen_string_literal: true

require_relative 'soml/version'

# Read and write SOML, a config format for humans.
#
# @see https://github.com/soml-lang/soml The specification
module SOML
	# The deepest nesting either direction accepts. Every array and object is one level, including the document's own collection.
	MAX_DEPTH = 100

	INT64_MIN = -(2**63)
	INT64_MAX = (2**63) - 1

	# The duration units in their required order, with their length in nanoseconds.
	DURATION_UNITS = {
		'h' => 3_600_000_000_000,
		'm' => 60_000_000_000,
		's' => 1_000_000_000,
		'ms' => 1_000_000,
		'us' => 1000,
		'ns' => 1
	}.freeze

	# A byte that a bare key can hold, as a table of 256 booleans, for the {Parser} and the {Tree}.
	BARE_KEY_BYTE = Array.new(256) { it.chr.match?(/[A-Za-z0-9_-]/) }.freeze

	# A number, an instant, or a duration is one maximal run of these bytes, which the {Parser} then validates as a whole. A keyword ends at the first byte that is not one, too, because the parser checked that it is followed by whitespace, a separator, a closing bracket, a comment, or the end.
	NUMBER_BYTE = Array.new(256) { it.chr.match?(/[A-Za-z0-9_.:+-]/) }.freeze

	# A line of a block string without one of these is blank. A search for one character, because a repeat over a long line needs memory for every character.
	NOT_BLANK_CHARACTER = /[^\t ]/

	# The default of the `value` of {SOML.edit}, which tells a missing value from `nil`.
	NO_VALUE = Object.new.freeze

	# The indentation of each level, so that the {Generator} and the {Printer} make no string for each line they indent. The {Printer} indents a value after a comment one level deeper than its key, so each container can be two levels deeper than the one that holds it, and a value after a comment in the deepest container is at level 200.
	INDENTS = Array.new((MAX_DEPTH * 2) + 1) { ("\t" * it).freeze }.freeze

	private_constant :MAX_DEPTH, :INT64_MIN, :INT64_MAX, :DURATION_UNITS, :NO_VALUE, :BARE_KEY_BYTE, :NUMBER_BYTE, :NOT_BLANK_CHARACTER, :INDENTS

	# Whether a key can be written without quotes, as a bare key: one or more ASCII letters, digits, `_`, or `-`, in any order, so `404` and `-x` are bare keys too. {SOML.generate} writes such a key bare and quotes every other key.
	#
	# @param key [String, Symbol] A key, or a symbol, which is read as its name. A key in an encoding that is not compatible with ASCII, such as UTF-16, is converted to UTF-8 first. Any other object gives false.
	# @return [Boolean]
	#
	# @example
	#   SOML.bare_key?('content-type')
	#   #=> true
	#
	#   SOML.bare_key?('a.b')
	#   #=> false
	def self.bare_key?(key)
		# Only a String or a Symbol is a key. Anything else, such as a number or nil, could never be a bare key, so the answer is false rather than a crash on its missing `encoding`.
		return false unless String === key || Symbol === key

		# The byte scan needs a String, so a Symbol is read as its name. A String, even a subclass, is left as it is.
		key = key.name if Symbol === key
		key = key.encode(Encoding::UTF_8) unless key.encoding.ascii_compatible?

		# A scan of the bytes, which is faster than the regex it replaces and decides the same: a byte that is not an ASCII letter, digit, `_`, or `-` means the key needs quotes. A non-ASCII character is a run of bytes none of which a bare key can hold.
		return false if key.empty?

		index = 0
		length = key.bytesize

		while index < length
			return false unless BARE_KEY_BYTE[key.getbyte(index)]

			index += 1
		end

		true
	rescue EncodingError
		# A key that does not convert to UTF-8.
		false
	end

	# Parse a document.
	#
	# @param source [String] The document. A UTF-8, binary, or US-ASCII string is read as UTF-8, and a string in another encoding is converted to UTF-8 first.
	# @param symbolize_names [Boolean] Whether object keys are symbols rather than strings.
	# @param freeze [Boolean] Whether the result is deeply frozen, which also makes it shareable between ractors.
	# @return [Hash, Array] The object or array the document contains.
	# @raise [ParseError] When the document is not valid.
	# @raise [TypeError] When `source` is not a string.
	# @raise [EncodingError] When `source` is in an encoding other than UTF-8, binary, or US-ASCII, and does not convert to UTF-8.
	#
	# @example
	#   SOML.parse(<<~SOML)
	#     name: 'api-gateway'
	#     replicas: 3
	#     timeout: 30s
	#     postgres: {host: 'db.internal'}
	#   SOML
	#   #=> {"name" => "api-gateway", "replicas" => 3, "timeout" => #<SOML::Duration 30s>, "postgres" => {"host" => "db.internal"}}
	def self.parse(source, symbolize_names: false, freeze: false) = Parser.new(source, symbolize_names:, freeze:).parse

	# Parse a document into a read-only syntax tree for linters and other tools. Nodes have decoded values, spelling, and UTF-8 byte spans. The tree holds a frozen copy of the source.
	#
	# @param source [String] The document, read as {SOML.parse} reads it.
	# @return [Tree] The deeply frozen tree, including its source, tokens, and comments.
	# @raise [ParseError, TypeError, EncodingError] As for {SOML.parse}.
	# @example
	#   tree = SOML.parse_tree('port: 0x1F90 # Default')
	#   node = tree.body.members.first.value
	#   [node.kind, node.value, node.radix, tree.position(node.start)]
	#   #=> [:integer, 8080, 16, [1, 7]]
	def self.parse_tree(source) = Tree.new(source)

	# Read and parse a file.
	#
	# The file is read in binary mode, so that a text-mode conversion cannot hide a carriage return. An error names the file, as in `Duplicate key port at config.soml:3:1`.
	#
	# @param path [String, #to_path] The file, such as a `Pathname` or a `File`.
	# @param symbolize_names [Boolean] See {SOML.parse}.
	# @param freeze [Boolean] See {SOML.parse}.
	# @return [Hash, Array] The object or array the document contains.
	# @raise [ParseError] When the document is not valid. Its message and {ParseError#path} name the file.
	# @raise [SystemCallError] When the file cannot be read, such as `Errno::ENOENT`.
	#
	# @example
	#   config = SOML.load_file('config.soml', symbolize_names: true)
	def self.load_file(path, symbolize_names: false, freeze: false) = Parser.new(File.binread(path), symbolize_names:, freeze:, path: File.path(path)).parse

	# Write a hash or an array as SOML.
	#
	# Members keep the order of their hash, nesting uses braces and tabs, and the text ends with one line feed. Everything but the member order follows canonical form.
	#
	# With `canonical: true`, members are sorted by key too, so two equal values give the same text, which can be hashed, signed, or compared.
	#
	# @param value [Hash, Array] The document.
	# @param canonical [Boolean] Whether to write canonical form, with members sorted by key.
	# @return [String] The text, in UTF-8.
	# @raise [GenerateError] For a value that cannot be written, such as NaN, an integer outside the 64-bit range, a key that is not a string or a symbol, or an object of another class.
	#
	# @example
	#   SOML.generate({name: 'api-gateway', replicas: 3, ratio: 0.5})
	#   #=> "name: 'api-gateway'\nreplicas: 3\nratio: 0.5\n"
	#
	#   SOML.generate({name: 'api-gateway', replicas: 3, ratio: 0.5}, canonical: true)
	#   #=> "name: 'api-gateway'\nratio: 0.5\nreplicas: 3\n"
	def self.generate(value, canonical: false) = Generator.new(canonical:).generate(value)

	# Format a document. Returns the document with its layout normalized, ending with one line feed.
	#
	# The layout follows the formatter in the specification: one tab per level, every member and item on its own line with no commas, and no trailing whitespace or runs of blank lines. A container on one line stays on one line, as in `ports: [80, 443]`. Put a line break anywhere inside it to split it. Comments, member order, block strings, and the spelling of every value stay as they are.
	#
	# In detail:
	#
	# - A block comment before a value on the same line, as in `1, /* note */ 2`, stays in front of that value.
	# - One space follows each `:`.
	# - A value on the line after its `key:` moves up to that line, unless a comment comes between them. Then it stays on its own line, one level deeper than the key.
	# - A block string begins on the line after its key, indented to that line. Its lines are not otherwise changed.
	# - There are no blank lines at the start of the file or directly inside brackets.
	#
	# @param source [String] The document, read as {SOML.parse} reads it.
	# @return [String] The formatted document, in UTF-8, ending with one line feed.
	# @raise [ParseError] When the document is not valid, the same as {SOML.parse}.
	# @raise [TypeError] When `source` is not a string.
	# @raise [EncodingError] When `source` is in an encoding other than UTF-8, binary, or US-ASCII, and does not convert to UTF-8.
	#
	# @example
	#   SOML.format('pool: {min: 2,   max: 16,} # Connections')
	#   #=> "pool: {min: 2, max: 16} # Connections\n"
	#
	#   SOML.format("pool: {\nmin: 2, max: 16}")
	#   #=> "pool: {\n\tmin: 2\n\tmax: 16\n}\n"
	def self.format(source) = Printer.new(Tree.new(source, lean: true)).print

	# Change one value in a document, and keep everything else as it is written: comments, member order, layout, and spelling. For tools that update a config file, such as a dependency bumper or a `set` command.
	#
	# Instead of a path, pass a member or a value node from {SOML.parse_tree} of the same source. A member selects its value for replacement and the whole member for deletion. Keys, comments, and the root collection cannot be edited this way. Reparse after each edit before selecting another node.
	#
	# The value at `path` is replaced, or added when it does not exist, and `delete: true` removes it. Only the changed part of the text is rewritten, so a formatted document stays formatted.
	#
	# - A new value is written as {SOML.generate} writes it (keeping member order), at the indentation of its line. So `0xFF` replaced by `255` is written `255`. In a one-line container, it is written on one line too, so `[1, 2]` with a new item `{a: 3}` becomes `[1, 2, {a: 3}]`.
	# - A new member goes after the last member of its object. Missing objects on the way are created.
	# - A new item can be added at the end of an array, at the index that is its length.
	# - A new member or item goes on its own line without a comma, after the comments that the one before it owns (see below). The commas of the others stay as they are. When something follows the one before it on the same line, such as the `}` of `{a: 1}`, it goes on that line after a comma, as in `{a: 1, b: 2}`. In an empty `[]` or `{}`, it goes on its own line, unless that container is inside a one-line container, so `a: [1, []]` becomes `a: [1, [2]]`.
	# - A removed member or item takes the comments it owns, which are the ones {SOML.format} keeps with it: the comments after it on its line (also after its comma), and the block comments before it on its line. So removing `2` from `[1, /* note */ 2]` gives `[1]`. A comment on a line of its own stays. Its lines are removed when nothing else is on them, including a line that a block comment after it continues onto. Removing every item of a container closes it up to `[]` or `{}`, unless a comment is left inside.
	# - A removed member or item takes its comma with it. When it is the last one without a comma after it, it takes the comma directly before it instead, so `[1, 2]` becomes `[1]`.
	# - Removing the only member of a document without braces leaves `{}`.
	#
	# Comments inside a replaced or removed value are removed with it. In a layout that {SOML.format} never writes, such as an item after a closing block string delimiter on its line, a new item can be indented differently from its neighbors, but the document is always valid. Removing a value that does not exist (a missing member, a missing object or array on the way, or an index at or past the end of its array) changes nothing, so it is safe to remove the same path twice. Use `SOML.edit(source, path, delete: true).b == source.b` to tell whether something was removed. The `.b` is needed because a source read in binary mode is not `==` to the UTF-8 result when it has non-ASCII characters.
	#
	# The result is parsed before it is returned, so a bug in `edit` raises a `RuntimeError` rather than returning a broken document.
	#
	# @overload edit(source, path, value)
	#   @param source [String] The document, read as {SOML.parse} reads it.
	#   @param path [Array<String, Symbol, Integer>, Tree::MemberNode, Tree::ObjectNode, Tree::ArrayNode, Tree::ScalarNode] A node from the same source, or the keys and array indexes that lead to the value, such as `['servers', 0, 'port']`.
	#   @param value [Object] The new value, of the types that {SOML.generate} accepts. Write a `Hash` with braces, because without them Ruby passes its members as keyword arguments.
	#   @return [String] The changed document, in UTF-8.
	# @overload edit(source, path, delete: true)
	#   @param source [String] The document, read as {SOML.parse} reads it.
	#   @param path [Array<String, Symbol, Integer>, Tree::MemberNode, Tree::ObjectNode, Tree::ArrayNode, Tree::ScalarNode] A node from the same source, or the keys and array indexes that lead to the value.
	#   @param delete [true] Remove the value.
	#   @return [String] The changed document, in UTF-8.
	# @raise [ParseError] When the document is not valid, the same as {SOML.parse}.
	# @raise [ArgumentError] When both a value and `delete: true` are given, or neither, or when the selected node is the root or cannot be found in the source.
	# @raise [TypeError] When `source` is not a string, when `path` is not a supported node or a non-empty array of keys and indexes, when it leads through a scalar, or when it has a key where an array is or an index where an object is.
	# @raise [IndexError] When a value is set at an index past the end of its array, or at an index under a missing value.
	# @raise [GenerateError] For a value or a key that {SOML.generate} cannot write, and when the change would nest more than 100 levels deep.
	# @raise [EncodingError] When `source` is in an encoding other than UTF-8, binary, or US-ASCII, and does not convert to UTF-8.
	#
	# @example
	#   SOML.edit("name: 'api' # The service\nport: 8080\n", ['port'], 9090)
	#   #=> "name: 'api' # The service\nport: 9090\n"
	#
	#   SOML.edit("postgres: {\n\thost: 'db'\n}\n", ['postgres', 'port'], 5432)
	#   #=> "postgres: {\n\thost: 'db'\n\tport: 5432\n}\n"
	#
	#   SOML.edit("a: 1\nb: 2\n", ['a'], delete: true)
	#   #=> "b: 2\n"
	def self.edit(source, path, value = NO_VALUE, delete: false)
		if delete
			raise ArgumentError, 'Pass either a value or delete: true, not both' unless NO_VALUE.equal?(value)
		elsif NO_VALUE.equal?(value)
			raise ArgumentError, 'Pass the new value, or delete: true to remove the value'
		end

		Editor.new(source, path, value, delete:).edit
	end
end

require_relative 'soml/error'
require_relative 'soml/duration'
require_relative 'soml/parser'
require_relative 'soml/generator'
require_relative 'soml/tree'
require_relative 'soml/format'
require_relative 'soml/edit'
