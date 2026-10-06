# frozen_string_literal: true

require_relative 'test_helper'

class TestTree < Minitest::Test
	def test_tokens_for_highlighting
		source = %q({'é': [0xFF, 1.5, infinity, -infinity, true, false, null, 2026-09-19T14:00:00Z, 30s, "a\n{}:#"], bare: {}} # note)
		tree = SOML.parse_tree(source)
		assert_equal [:punctuator, :string, :punctuator, :punctuator, :integer, :punctuator, :float, :punctuator, :float, :punctuator, :float, :punctuator, :keyword, :punctuator, :keyword, :punctuator, :keyword, :punctuator, :instant, :punctuator, :duration, :punctuator, :string, :punctuator, :punctuator, :bare_key, :punctuator, :punctuator, :punctuator, :punctuator], tree.tokens.map(&:type)
		assert_equal '0xFF', tree.tokens[4].value
		assert_equal '"a\n{}:#"', tree.tokens[22].value
		assert_equal "'é'", tree.tokens[1].value
		assert_equal [1, 2], tree.position(tree.tokens[1].start)
		assert_equal 5, tree.tokens[1].finish
		assert tree.tokens.frozen?
		assert_raises(FrozenError) { tree.tokens.clear }
		assert_raises(FrozenError) { tree.tokens.first.value.clear }
		assert_raises(FrozenError) { tree.tokens.first.type = :string }
	end

	def test_block_strings_and_comments_do_not_emit_inner_tokens
		source = <<~'SOML'
			# []: true
			a: '''
			[false, {}] # text
			''' /* : null */
			b: """
			hello\n{}
			"""
		SOML
		tree = SOML.parse_tree(source)
		assert_equal [:bare_key, :punctuator, :string, :bare_key, :punctuator, :string], tree.tokens.map(&:type)
		assert_equal "'''\n[false, {}] # text\n'''", tree.tokens[2].value
		assert_equal [:line, :block], tree.comments.map(&:type)
	end

	def test_scalar_values_and_spelling
		source = <<~SOML
			bare: [0b11, 0o10, 0xFF, -42, 1.5, infinity, -infinity, true, false, null, 2026-09-19T14:00:00.123456789Z, -1h1.5m]
			'literal': 'é'
			"escaped\\tkey": "a\\nb"
			block:
				'''
				hello
				'''
		SOML
		tree = SOML.parse_tree(source)
		assert_same_value SOML.parse(source), value_of(tree.body)
		scalars = tree.body.members.first.value.elements
		assert_equal [:integer, :integer, :integer, :integer, :float, :float, :float, :boolean, :boolean, :null, :instant, :duration], scalars.map(&:kind)
		assert_equal [2, 8, 16, 10], scalars.first(4).map(&:radix)
		assert_equal [:bare, :literal, :escaped, :bare], tree.body.members.map { it.key.style }
		assert_equal [:literal, :escaped, :literal], tree.body.members.drop(1).map { it.value.style }
		assert tree.body.members.last.value.block
		assert_equal "escaped\tkey", tree.body.members[2].key.value
		assert_nil scalars[4].radix
		assert_nil scalars[0].style
	end

	def test_traversal_and_comments
		tree = SOML.parse_tree("# before\na: [{b: 1}] /* after */\n")
		assert_instance_of Enumerator, tree.each_node
		assert_equal [:object, :member, :key, :array, :object, :member, :key, :scalar], tree.each_node.map(&:type)
		assert_equal [:line, :block], tree.comments.map(&:type)
		assert_equal [' before', ' after '], tree.comments.map(&:value)
		assert_equal ['# before', '/* after */'], tree.comments.map { tree.source.byteslice(it.start...it.finish) }
		assert_same tree, tree.each_node { |_node| }
		refute tree.body.braced
		assert SOML.parse_tree('{}').body.braced
	end

	def test_byte_spans_and_positions
		tree = SOML.parse_tree("# é\n'é': ['😀', 42]\n")
		integer = tree.body.members.first.value.elements.last
		assert_equal '42', tree.source.byteslice(integer.start...integer.finish)
		assert_equal [2, 12], tree.position(integer.start)
		assert_equal [1, 1], tree.position(0)
		assert_equal [3, 1], tree.position(tree.source.bytesize)
		assert_equal [2, 1], tree.position(tree.body.start)
		assert_equal [2, 15], tree.position(tree.body.finish)
		assert_raises(TypeError) { tree.position(1.0) }
		[-1, tree.source.bytesize + 1, 3].each do |offset|
			assert_raises(ArgumentError) { tree.position(offset) }
		end
	end

	def test_immutable_snapshot
		source = +"a: ['text', 2026-09-19T14:00:00Z] # comment"
		tree = SOML.parse_tree(source)
		refute source.frozen?
		source.replace('changed')
		assert_equal "a: ['text', 2026-09-19T14:00:00Z] # comment", tree.source
		assert Ractor.shareable?(tree)
		assert tree.each_node.all?(&:frozen?)
		assert tree.body.members.first.value.elements.frozen?
		assert_raises(FrozenError) { tree.source.clear }
		assert_raises(FrozenError) { tree.body.members.clear }
		assert_raises(FrozenError) { tree.body.members.first.value.elements.first.value.clear }
		assert_raises(FrozenError) { tree.body.members.first.value.elements.last.value.localtime }
		assert_raises(FrozenError) { tree.comments.first.value.clear }
		assert_raises(FrozenError) { tree.body.members.first.key.value = 'other' }
	end

	def test_positions_at_every_unicode_boundary
		tree = SOML.parse_tree("'é😀': ['é',\n\t'界'] # end\n")
		byte_offset = 0
		line = column = 1
		tree.source.each_char do |character|
			assert_equal [line, column], tree.position(byte_offset)
			(1...character.bytesize).each do |inside|
				assert_raises(ArgumentError) { tree.position(byte_offset + inside) }
			end
			byte_offset += character.bytesize
			if character == "\n"
				line += 1
				column = 1
			else
				column += 1
			end
		end
		assert_equal [line, column], tree.position(byte_offset)
	end

	def test_source_conversion
		text = "'é': '😀'"
		[text, text.b, text.encode(Encoding::UTF_16LE)].each do |source|
			tree = SOML.parse_tree(source)
			assert_equal text, tree.source
			assert_equal Encoding::UTF_8, tree.source.encoding
			assert_same_value SOML.parse(source), value_of(tree.body)
		end
		coercible = Object.new
		def coercible.to_str = 'a: 1'
		assert_equal 'a: 1', SOML.parse_tree(coercible).source
		assert_raises(TypeError) { SOML.parse_tree(42) }
	end

	def test_conformance
		root = File.join(__dir__, 'conformance')
		Dir.glob('valid/**/*.soml', base: root).each do |name|
			source = File.binread(File.join(root, name))
			tree = SOML.parse_tree(source)
			assert_same_value SOML.parse(source), value_of(tree.body), name
			assert_equal tree.tokens.sort_by(&:start), tree.tokens, name
			assert_equal tree.comments.sort_by(&:start), tree.comments, name
			position = 0
			(tree.tokens + tree.comments).sort_by(&:start).each do |token|
				assert_operator token.start, :>=, position, name
				assert_match(/\A[ \t\n]*\z/, tree.source.byteslice(position...token.start), name)
				assert_operator token.finish, :>, token.start, name
				assert tree.source.byteslice(token.start...token.finish).valid_encoding?, name
				if SOML::Tree::Token === token
					assert_equal tree.source.byteslice(token.start...token.finish), token.value, name
				end
				position = token.finish
			end
			assert_match(/\A[ \t\n]*\z/, tree.source.byteslice(position..), name)
			tree.each_node do |node|
				assert_operator node.start, :<, node.finish, name
				assert tree.source.byteslice(node.start...node.finish).valid_encoding?, name
			end
		end
		Dir.glob('invalid/**/*.soml', base: root).each do |name|
			source = File.binread(File.join(root, name))
			expected = assert_raises(SOML::ParseError) { SOML.parse(source) }
			actual = assert_raises(SOML::ParseError) { SOML.parse_tree(source) }
			assert_equal [expected.reason, expected.offset, expected.line, expected.column], [actual.reason, actual.offset, actual.line, actual.column], name
		end
	end

	def test_editing_nodes_uses_existing_edit_rules
		source = "name: 'é'\nservers: [{port: 0x1F90 # default\n}, {port: 80}]\n"
		tree = SOML.parse_tree(source)
		member = tree.body.members.last.value.elements.first.members.first
		[member, member.value].each do |node|
			assert_equal SOML.edit(source, ['servers', 0, 'port'], 9090), SOML.edit(source, node, 9090)
			assert_equal SOML.edit(source, ['servers', 0, 'port'], delete: true), SOML.edit(source, node, delete: true)
		end
		array = tree.body.members.last.value
		assert_equal SOML.edit(source, ['servers'], []), SOML.edit(source, array, [])
		assert_equal SOML.edit(source, ['servers', 1], delete: true), SOML.edit(source, array.elements.last, delete: true)
		assert_raises(ArgumentError) { SOML.edit(source, tree.body, {}) }
		assert_raises(TypeError) { SOML.edit(source, member.key, 'new') }
		assert_raises(TypeError) { SOML.edit(source, tree.comments.first, 'new') }
		assert_raises(ArgumentError) { SOML.edit(source, SOML.parse_tree('a: 1').body.members.first.value, 2) }
	end

	def test_node_edits_preserve_block_string_and_comment_rules
		source = "a:\n\t'''\n\ttext\n\t''' # keep\nb: 2\n"
		member = SOML.parse_tree(source).body.members.first
		assert_equal "a: 'new' # keep\nb: 2\n", SOML.edit(source, member.value, 'new')
		assert_equal "b: 2\n", SOML.edit(source, member, delete: true)
		source = '[1, /* remove */ 1, 1]'
		item = SOML.parse_tree(source).body.elements[1]
		assert_equal '[1, /* remove */ 2, 1]', SOML.edit(source, item, 2)
		assert_equal '[1, 1]', SOML.edit(source, item, delete: true)
		assert_raises(TypeError) { SOML.edit(source, SOML.parse_tree(source).tokens.first, 2) }
	end

	def test_every_node_is_found_by_its_own_path
		source = <<~SOML
			a: [{b: [1, 1, {c: []}]}, {}, [[], [1]]] # note
			'd e': {f: {}}
			g: '''
				text
				'''
		SOML
		tree = SOML.parse_tree(source)
		paths = {}
		walk = lambda do |node, path|
			case node.type
			when :object
				node.members.each do |member|
					paths[member] = [*path, member.key.value]
					paths[member.value] = [*path, member.key.value]
					walk.(member.value, [*path, member.key.value])
				end
			when :array
				node.elements.each_with_index do |element, index|
					paths[element] = [*path, index]
					walk.(element, [*path, index])
				end
			end
		end
		walk.(tree.body, [])
		paths.each do |node, path|
			assert_equal SOML.edit(source, path, 'x'), SOML.edit(source, node, 'x'), path.inspect
			assert_equal SOML.edit(source, path, delete: true), SOML.edit(source, node, delete: true), path.inspect
		end
	end

	def test_a_node_that_is_not_in_the_source_is_rejected
		source = "a: [1, 2]\nb: {c: 3}\n"
		[
			SOML.parse_tree('{}').body,
			SOML.parse_tree("a: [1, 3]\nb: {c: 3}\n").body.members.first.value.elements.last,
			SOML.parse_tree("a: [1, 2]\nb: {d: 3}\n").body.members.last,
			SOML.parse_tree("x: [1, 2]\nb: {c: 3}\n").body.members.first,
			SOML.parse_tree('[[1, 2]]').body.elements.first,
			SOML.parse_tree(source).body
		].each do |node|
			assert_raises(ArgumentError) { SOML.edit(source, node, 1) }
		end
	end

	def test_radix_and_style_of_every_spelling
		tree = SOML.parse_tree("[0, 0.5, 0e0, 10, -1, 0b1, 0o7, 0xA, 1_000, 'a', \"b\", '''\nc\n''', \"\"\"\nd\n\"\"\"]")
		elements = tree.body.elements
		assert_equal [10, nil, nil, 10, 10, 2, 8, 16, 10, nil, nil, nil, nil], elements.map(&:radix)
		assert_equal [nil] * 9 + [:literal, :escaped, :literal, :escaped], elements.map(&:style)
		assert_equal [false] * 11 + [true, true], elements.map(&:block)
		assert_equal 10, SOML.parse_tree('a: 0').body.members.first.value.radix
	end

	def test_position_of_the_end_of_every_line
		source = "a: 'é'\n\nb: [\n\t1\n]\n"
		tree = SOML.parse_tree(source)
		line_ends = source.b.enum_for(:scan, "\n").map { Regexp.last_match.begin(0) }
		assert_equal [[1, 7], [2, 1], [3, 5], [4, 3], [5, 2]], line_ends.map { tree.position(it) }
		assert_equal [[2, 1], [3, 1], [4, 1], [5, 1], [6, 1]], line_ends.map { tree.position(it + 1) }
		assert_equal [1, 1], SOML.parse_tree('[]').position(0)
		assert_equal [1, 3], SOML.parse_tree('[]').position(2)
	end

	# A long non-ASCII source counts its columns from the character counts at every 1024th byte, so every boundary around those is checked, on long lines and on short ones.
	def test_positions_in_a_long_non_ascii_source
		items = (0...900).map { ["'é'", "'😀'", "'ab'", "'界x'"][it % 4] }
		source = "a: [#{items.join(', ')}]\nb: [\n#{items.each_slice(7).map { "\t#{it.join(', ')}," }.join("\n")}\n]\nc: 'é'"
		tree = SOML.parse_tree(source)
		assert_operator source.bytesize, :>, 8 * 1024
		offset = 0

		source.each_char do |character|
			before = source.byteslice(0, offset)
			assert_equal [before.count("\n") + 1, before.length - (before.rindex("\n") || -1)], tree.position(offset), offset
			offset += character.bytesize
		end

		assert_equal [source.count("\n") + 1, source.length - source.rindex("\n")], tree.position(offset)
	end

	def test_linter_text_fixes_use_byte_offsets
		tree = SOML.parse_tree("name: '😀'\na: 0xFF\nb: 0b11 # keep\n")
		fixes = tree.each_node.select { it.type == :scalar && it.kind == :integer && it.radix != 10 }
		result = tree.source.b.dup
		fixes.reverse_each do |node|
			result[node.start...node.finish] = node.value.to_s
		end
		result.force_encoding(Encoding::UTF_8)
		assert_equal "name: '😀'\na: 255\nb: 3 # keep\n", result
		assert_same_value SOML.parse(tree.source), SOML.parse(result)
	end

	private

	def value_of(node)
		case node.type
		when :object
			node.members.to_h { [it.key.value, value_of(it.value)] }
		when :array
			node.elements.map { value_of(it) }
		else
			node.value
		end
	end
end
