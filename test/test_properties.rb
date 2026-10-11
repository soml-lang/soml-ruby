# frozen_string_literal: true

# Property tests with a seeded random generator. Set `SOML_SEED` to repeat a run, and `SOML_EXAMPLES` for more examples.

require_relative 'test_helper'

class TestProperties < Minitest::Test
	SEED = ENV.key?('SOML_SEED') ? Integer(ENV['SOML_SEED'], 10) : Random.new_seed % 1_000_000
	EXAMPLES = Integer(ENV.fetch('SOML_EXAMPLES', '300'), 10)

	# Characters a string may hold, weighted toward the ones with rules: quotes, backslashes, controls, invisible characters, and characters outside the BMP.
	CHARACTERS = [
		*('a'..'e'), *('0'..'3'), ' ', '_', '-', '.', ':', '#', '/', '*', '{', '}', '[', ']', ',',
		"'", '"', '\\', "\t", "\n", "\u0000", "\u0001", "\u001F", "\u007F", "\u0085", " ", "é",
		"​", " ", "‮", "﻿", "￿", "\u{1F600}", "\u{10FFFF}", "\u{FDD0}"
	].freeze

	class Values
		def initialize(random)
			@random = random
		end

		def document
			@random.rand < 0.75 ? object(1) : array(1)
		end

		def value(depth)
			case @random.rand(depth < 6 ? 12 : 9)
			when 0, 1 then string
			when 2 then integer
			when 3 then float
			when 4 then [true, false].sample(random: @random)
			when 5 then nil
			when 6 then instant
			when 7 then duration
			when 8 then [string, integer].sample(random: @random)
			when 9 then array(depth + 1)
			else object(depth + 1)
			end
		end

		def array(depth)
			Array.new(@random.rand(4)) { value(depth) }
		end

		def object(depth)
			Array.new(@random.rand(5)) { [key, value(depth)] }.to_h
		end

		def key
			@random.rand < 0.7 ? Array.new(@random.rand(1..6)) { [*('a'..'c'), '0', '-', '_'].sample(random: @random) }.join : string
		end

		def string
			Array.new(@random.rand(8)) { CHARACTERS.sample(random: @random) }.join.force_encoding(Encoding::UTF_8)
		end

		def integer
			case @random.rand(4)
			when 0 then [0, 1, -1, (2**63) - 1, -(2**63)].sample(random: @random)
			when 1 then @random.rand(-1000..1000)
			else @random.rand(-(2**63)..((2**63) - 1))
			end
		end

		def float
			case @random.rand(4)
			when 0
				[0.0, 1.0, -1.5, 0.1, 1e21, 1e-7, 5e-324, Float::MAX, -Float::MAX, Float::INFINITY, -Float::INFINITY, 2.2250738585072014e-308].sample(random: @random)
			when 1
				@random.rand(-1000.0..1000.0)
			else
				# Any bit pattern, except NaN.
				value = [@random.rand(2**64)].pack('Q').unpack1('D')
				value.nan? ? 0.5 : value
			end
		end

		def instant
			seconds = @random.rand(-62_135_596_800..253_402_300_799)
			nanoseconds = [0, @random.rand(1_000_000_000), @random.rand(1000) * 1_000_000].sample(random: @random)
			Time.at(seconds, nanoseconds, :nsec, in: 'UTC')
		end

		def duration
			nanoseconds = case @random.rand(3)
			when 0 then [0, 1, -1, (2**63) - 1, -(2**63)].sample(random: @random)
			when 1 then @random.rand(-10_000..10_000) * [1, 1_000_000, 1_000_000_000, 60_000_000_000].sample(random: @random)
			else @random.rand(-(2**63)..((2**63) - 1))
			end

			SOML::Duration.new(nanoseconds:)
		end
	end

	# Writes a value in a random legal spelling, with comments and whitespace wherever the grammar allows them, so that every spelling must read back as the same value.
	class Respeller
		def initialize(random)
			@random = random
		end

		def document(value)
			if value.is_a?(Hash) && !value.empty? && @random.rand < 0.6
				# A brace-less top level separates its entries with line breaks.
				entries = value.map { |key, member| entry(key, member, '') }.shuffle(random: @random)
				return "#{gap}#{entries.join(line_break)}#{gap}"
			end

			"#{gap}#{container(value, '')}#{gap}"
		end

		private

		def entry(key, value, indent)
			"#{key_text(key)}:#{inline_gap}#{item(value, indent)}"
		end

		def container(value, indent)
			inner = "#{indent}\t"

			items = if value.is_a?(Array)
				value.map { item(it, inner) }
			else
				value.map { |key, member| entry(key, member, inner) }.shuffle(random: @random)
			end

			# Items are separated by a comma, a line break, or both, and a comma goes on the line of the item before it.
			separators = Array.new([items.length - 1, 0].max) { separator }
			separators << ',' if !items.empty? && @random.rand < 0.5
			text = items.each_with_index.map { |item_text, index| "#{gap}#{item_text}#{separators[index] == ',' ? inline_gap : gap}#{separators[index]}" }.join
			text += gap if separators.length == items.length
			text = gap if items.empty?
			value.is_a?(Array) ? "[#{text}]" : "{#{text}}"
		end

		def item(value, indent)
			case value
			when Hash, Array then container(value, indent)
			when String then string(value, indent)
			when Integer then integer(value)
			when Float then float(value)
			when Time then instant(value)
			when SOML::Duration then duration(value)
			when nil then 'null'
			else value.to_s
			end
		end

		def gap
			['', ' ', "\n", "\t", " # note\n", "\n# note\n", ' /* note */ ', "/*\nnote\n*/"].sample(random: @random) + (@random.rand < 0.5 ? "\n" : '')
		end

		def separator
			@random.rand < 0.5 ? ',' : line_break
		end

		# Whitespace and comments where a line break is not allowed outside a comment.
		def inline_gap
			['', ' ', "\t", ' /* note */ ', "/*\nnote\n*/"].sample(random: @random)
		end

		def line_break
			["\n", "\n\n", " # note\n", "\n/* note */\n", "\t\n "].sample(random: @random)
		end

		def key_text(key)
			return key if key.match?(/\A[A-Za-z0-9_-]+\z/) && @random.rand < 0.8

			literal?(key) && @random.rand < 0.5 ? "'#{key}'" : escaped(key)
		end

		def literal?(string)
			!string.match?(/[\x00-\x1F'\x7F]/) || (string.match?(/\A[^\x00-\x08\x0A-\x1F'\x7F]*\z/) && !string.include?("\n"))
		end

		def string(value, indent)
			choice = @random.rand(4)
			return "'#{value}'" if choice.zero? && literal?(value)
			return escaped_block(value, indent) if choice == 1

			escaped(value)
		end

		# Every character may be written as itself or as an escape, and the ones that must be escaped are.
		def escaped(value)
			body = value.each_char.map do |character|
				if character == '\\'
					'\\\\'
				elsif character == '"'
					'\\"'
				elsif character == "\n"
					'\\n'
				elsif character.match?(/[\x00-\x1F\x7F]/) || @random.rand < 0.1
					character == "\t" && @random.rand < 0.5 ? '\\t' : "\\u{#{character.ord.to_s(16)}}"
				else
					character
				end
			end

			"\"#{body.join}\""
		end

		# A `"""` block whose lines are indented like the closing delimiter. A line break in the value is a line break in the block, except where that would make a blank line at the start or the end, which a block does not keep.
		def escaped_block(value, indent)
			return "\"\"\"\n#{indent}\t\"\"\"" if value.empty?

			lines = value.split("\n", -1).map do |line|
				text = escaped(line)[1...-1]

				# A line of only spaces and tabs counts as empty, so its first character is written as an escape.
				text.match?(/\A[ \t]+\z/) ? "\\u{#{text.ord.to_s(16)}}#{text[1..]}" : text
			end

			joined = [lines.first]

			lines.drop(1).each do |line|
				if joined.last.empty? && joined.length == 1
					joined[-1] = "#{joined.last}\\n#{line}"
				else
					joined << line
				end
			end

			# Empty lines at the end are joined to the line before them.
			while joined.length > 1 && joined.last.empty?
				last = joined.pop
				joined[-1] = "#{joined[-1]}\\n#{last}"
			end
			body = joined.map { it.empty? ? '' : "#{indent}\t#{it}" }.join("\n")
			"\"\"\"\n#{body}\n#{indent}\t\"\"\""
		end

		def integer(value)
			return value.to_s if value.negative? || @random.rand < 0.3

			text = case @random.rand(4)
			when 0 then "0x#{'0' * @random.rand(3)}#{value.to_s(16).upcase}"
			when 1 then "0o#{value.to_s(8)}"
			when 2 then "0b#{value.to_s(2)}"
			else value.to_s
			end

			underscores(text)
		end

		# An underscore between two random digits.
		def underscores(text)
			return text if @random.rand < 0.5

			start = text.start_with?('0x', '0o', '0b') ? 2 : 0
			candidates = (start + 1...text.length).select { |index| text[index - 1].match?(/[0-9A-F]/) && text[index].match?(/[0-9A-F]/) }
			return text if candidates.empty?

			index = candidates.sample(random: @random)
			"#{text[0, index]}_#{text[index..]}"
		end

		def float(value)
			text = SOML.generate([value])[/\t(.*)\n/, 1]
			return text if value.infinite? || value.zero? || @random.rand < 0.4

			# The same value as digits and a decimal exponent, with the point after the first digit.
			sign, whole, fraction, exponent = text.match(/\A(-?)([0-9]+)(?:\.([0-9]+))?(?:e(-?[0-9]+))?\z/).captures
			fraction = '' if fraction == '0' && exponent.nil?
			digits = "#{whole}#{fraction}"
			exponent = exponent.to_i - fraction.to_s.length
			significant = digits.lstrip('0')
			"#{sign}#{significant[0]}.#{significant.length > 1 ? significant[1..] : '0'}e#{exponent + significant.length - 1}"
		end

		def instant(value)
			offset_minutes = @random.rand < 0.5 ? 0 : @random.rand(-23 * 60..23 * 60)
			local = value + (offset_minutes * 60)

			# The offset must not move the value outside the years 0001 to 9999.
			return SOML.generate([value])[/\t(.*)\n/, 1] unless local.year.between?(1, 9999)

			fraction = local.nsec.zero? && @random.rand < 0.5 ? '' : ".#{format('%09d', local.nsec)}"
			sign = offset_minutes.negative? ? '-' : '+'
			offset = offset_minutes.zero? && @random.rand < 0.5 ? 'Z' : format('%s%02d:%02d', sign, offset_minutes.abs / 60, offset_minutes.abs % 60)
			offset = 'Z' if offset == '-00:00'
			format('%04d-%02d-%02dT%02d:%02d:%02d%s%s', local.year, local.month, local.day, local.hour, local.min, local.sec, fraction, offset)
		end

		UNITS = {'h' => 3_600_000_000_000, 'm' => 60_000_000_000, 's' => 1_000_000_000, 'ms' => 1_000_000, 'us' => 1000, 'ns' => 1}.freeze

		def duration(value)
			nanoseconds = value.nanoseconds
			return value.to_s if nanoseconds.zero? || @random.rand < 0.3

			sign = nanoseconds.negative? ? '-' : ''
			sign + (@random.rand < 0.5 ? duration_parts(nanoseconds.abs) : duration_fraction(nanoseconds.abs))
		end

		# A random set of units, each holding as much as it can, so `90m` and `5400s` are as likely as `1h30m`.
		def duration_parts(magnitude)
			units = UNITS.keys.select { @random.rand < 0.5 } | ['ns']
			rest = magnitude

			parts = UNITS.slice(*units).filter_map do |unit, size|
				count, rest = rest.divmod(size)
				"#{underscores(count.to_s)}#{unit}" if count.positive?
			end

			parts.join
		end

		# The whole value as a fraction of one unit, when that fraction is a terminating decimal.
		def duration_fraction(magnitude)
			unit, size = UNITS.to_a.sample(random: @random)
			whole, rest = magnitude.divmod(size)
			return "#{whole}#{unit}" if rest.zero?

			places = (1..40).find { |each_places| ((rest * (10**each_places)) % size).zero? }
			return duration_parts(magnitude) if places.nil?

			"#{whole}.#{((rest * (10**places)) / size).to_s.rjust(places, '0')}#{unit}"
		end
	end

	def test_generate_then_parse_gives_the_same_value
		random = Random.new(SEED)
		values = Values.new(random)

		EXAMPLES.times do
			value = values.document
			text = SOML.generate(value)
			assert_same_value value, SOML.parse(text), "seed #{SEED}: #{text.inspect}"
		end
	end

	def test_generate_is_a_fixed_point
		random = Random.new(SEED + 1)
		values = Values.new(random)

		EXAMPLES.times do
			text = SOML.generate(values.document)
			assert_equal text, SOML.generate(SOML.parse(text)), "seed #{SEED}"
		end
	end

	def test_every_spelling_gives_the_same_value
		random = Random.new(SEED + 2)
		values = Values.new(random)
		respeller = Respeller.new(random)

		EXAMPLES.times do
			value = values.document
			text = respeller.document(value)

			begin
				parsed = SOML.parse(text)
			rescue SOML::ParseError => error
				flunk "seed #{SEED}: #{error.message}\n#{text}"
			end

			assert_same_value value, parsed, "seed #{SEED}: #{text}"
			assert_equal SOML.generate(value, canonical: true), SOML.generate(parsed, canonical: true)
		end
	end

	MUTATIONS = ["'", '"', '\\', ':', ',', '.', '{', '}', '[', ']', '#', '/*', '*/', "\n", ' ', '-', '_', 'e', '0', '9', 'x', 'T', 'Z', 's', 'u{', "'''\n", "\r", " ", "\xFF".b, "\xC3".b].freeze

	def test_a_mutated_document_is_either_valid_or_a_parse_error
		random = Random.new(SEED + 3)
		documents = Dir.glob(File.join(__dir__, 'conformance', 'valid', '**', '*.soml')).sort.map { File.binread(it) }

		(EXAMPLES * 10).times do
			bytes = mutate(documents.sample(random:), random)
			bytes = mutate(bytes, random) while random.rand < 0.7

			begin
				value = SOML.parse(bytes)
			rescue SOML::ParseError => error
				# The position is consistent with the text before the offset, which is valid UTF-8 even when the error is a byte that is not.
				before = bytes.dup.force_encoding(Encoding::UTF_8)[0, error.offset]
				assert_equal [before.count("\n") + 1, before.length - (before.rindex("\n") || -1)], [error.line, error.column], "seed #{SEED}: #{bytes.inspect}"
				assert_includes error.code_frame, "> #{error.line} |"
				assert_match(/\n {#{error.line.to_s.length + 3}}\|[ \t]*\^\z/, error.code_frame)
				next
			end

			text = SOML.generate(value)
			assert_same_value value, SOML.parse(text), "seed #{SEED}: #{bytes.inspect}"
		end
	end

	# The output of `generate` follows every layout rule of the formatter, so formatting it changes nothing.
	def test_generate_is_already_formatted
		random = Random.new(SEED + 4)
		values = Values.new(random)

		EXAMPLES.times do
			value = values.document

			[SOML.generate(value), SOML.generate(value, canonical: true)].each do |text|
				assert_equal text, SOML.format(text), "seed #{SEED}"
			end
		end
	end

	def test_format_keeps_the_value_and_the_comments_and_is_a_fixed_point
		random = Random.new(SEED + 5)
		values = Values.new(random)
		respeller = Respeller.new(random)

		EXAMPLES.times do
			text = respeller.document(values.document)
			formatted = SOML.format(text)
			message = "seed #{SEED}: #{text.inspect}"

			assert_same_value SOML.parse(text), SOML.parse(formatted), message
			assert_equal formatted, SOML.format(formatted), message

			# Every comment of the respeller says “note”, which no generated string or key holds.
			assert_equal text.scan('note').length, formatted.scan('note').length, message
			refute_includes formatted, "\n\n\n", message
			refute formatted.start_with?("\n"), message
		end
	end

	# An edit of the text of `generate` is the text of `generate` for the edited value, byte for byte: a replaced member keeps its place, a new one goes last, and a removed one goes, as in the hash. The one exception is a new member of the empty document `{}`, which goes inside its braces.
	def test_an_edit_of_generated_text_is_the_generated_text_of_the_edited_value
		random = Random.new(SEED + 6)
		values = Values.new(random)

		EXAMPLES.times do
			value = values.document
			text = SOML.generate(value)
			path, new_value, is_delete = random_edit(value, values, random)
			next if text == "{}\n" && !is_delete

			result = is_delete ? SOML.edit(text, path, delete: true) : SOML.edit(text, path, new_value)
			assert_equal SOML.generate(edited(value, path, new_value, is_delete)), result, "seed #{SEED}: #{text.inspect} #{path.inspect}"
		end
	end

	def test_an_edit_changes_the_value_and_keeps_a_formatted_document_formatted
		random = Random.new(SEED + 7)
		values = Values.new(random)
		respeller = Respeller.new(random)

		EXAMPLES.times do
			formatted = SOML.format(respeller.document(values.document))
			value = SOML.parse(formatted)
			path, new_value, is_delete = random_edit(value, values, random)
			result = is_delete ? SOML.edit(formatted, path, delete: true) : SOML.edit(formatted, path, new_value)
			message = "seed #{SEED}: #{formatted.inspect} #{path.inspect}"

			assert_same_value edited(value, path, new_value, is_delete), SOML.parse(result), message
			assert_equal result, SOML.format(result), message
		end
	end

	# The tokens and the comments of every spelling cover the source in order with only whitespace between them, every node holds the value that `parse` reads, and every position is the line and column of the text before it.
	def test_the_syntax_tree_of_every_spelling_covers_the_source
		random = Random.new(SEED + 8)
		values = Values.new(random)
		respeller = Respeller.new(random)

		EXAMPLES.times do
			text = respeller.document(values.document)
			tree = SOML.parse_tree(text)
			message = "seed #{SEED}: #{text.inspect}"
			position = 0

			(tree.tokens + tree.comments).sort_by(&:start).each do |token|
				assert_match(/\A[ \t\n]*\z/, text.byteslice(position...token.start), message)
				position = token.finish
			end

			assert_match(/\A[ \t\n]*\z/, text.byteslice(position..), message)
			assert_same_value SOML.parse(text), tree_value(tree.body), message

			tree.each_node.each_cons(2) do |node, following|
				assert_operator node.start, :<=, following.start, message
			end

			tree.each_node do |node|
				before = text.byteslice(0, node.start)
				assert_equal [before.count("\n") + 1, before.length - (before.rindex("\n") || -1)], tree.position(node.start), message
			end
		end
	end

	# An edit through a member or a value node is the same as an edit through its path.
	def test_an_edit_through_a_node_is_an_edit_through_its_path
		random = Random.new(SEED + 9)
		values = Values.new(random)
		respeller = Respeller.new(random)

		EXAMPLES.times do
			text = respeller.document(values.document)
			tree = SOML.parse_tree(text)
			nodes = node_paths(tree.body, [])
			next if nodes.empty?

			node, path = nodes.sample(random:)
			new_value = values.value(path.length + 1)
			message = "seed #{SEED}: #{text.inspect} #{path.inspect}"

			assert_equal SOML.edit(text, path, new_value), SOML.edit(text, node, new_value), message
			assert_equal SOML.edit(text, path, delete: true), SOML.edit(text, node, delete: true), message
		end
	end

	private

	def tree_value(node)
		case node.type
		when :object
			node.members.to_h { [it.key.value, tree_value(it.value)] }
		when :array
			node.elements.map { tree_value(it) }
		else
			node.value
		end
	end

	# Every member and non-root value node under `node`, each with its path.
	def node_paths(node, path)
		case node.type
		when :object
			node.members.flat_map { [[it, [*path, it.key.value]], [it.value, [*path, it.key.value]], *node_paths(it.value, [*path, it.key.value])] }
		when :array
			node.elements.each_with_index.flat_map { |element, index| [[element, [*path, index]], *node_paths(element, [*path, index])] }
		else
			[]
		end
	end

	# A path to an existing value, to a new member, or to a new item at the end of an array, with a new value or a removal.
	def random_edit(value, values, random)
		paths = []
		collect_paths(value, [], paths)
		path = paths.sample(random:)
		is_delete = random.rand < 0.4
		[path, is_delete ? nil : values.value(path.length + 1), is_delete]
	end

	def collect_paths(value, path, paths)
		paths << path unless path.empty?

		case value
		when Hash
			value.each { |key, member| collect_paths(member, [*path, key], paths) }
			paths << [*path, 'new-key']
		when Array
			value.each_with_index { |item, index| collect_paths(item, [*path, index], paths) }
			paths << [*path, value.length]
		end
	end

	# `value` with the change of `path` made, as a copy.
	def edited(value, path, new_value, is_delete)
		copy = Marshal.load(Marshal.dump(value))
		*parents, last = path
		container = parents.reduce(copy) { |node, segment| node[segment] }

		if !is_delete
			container[last] = new_value
		elsif container.is_a?(Array)
			container.delete_at(last)
		else
			container.delete(last)
		end

		copy
	end

	def mutate(bytes, random)
		bytes = bytes.b
		index = random.rand(bytes.bytesize + 1)

		case random.rand(3)
		when 0 then bytes.insert(index, MUTATIONS.sample(random:).b)
		when 1 then bytes.byteslice(0, index) + bytes.byteslice(index + 1, bytes.bytesize).to_s
		else bytes.byteslice(0, index) + MUTATIONS.sample(random:).b + bytes.byteslice(index + 1, bytes.bytesize).to_s
		end
	end
end
