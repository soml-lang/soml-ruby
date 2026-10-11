# soml-lang

> Read and write [SOML](https://soml.sh), a config format for humans, in Ruby

> [!NOTE]
> The format is a draft.

## Highlights

- Strict: enforces every rule in the specification, with the same error messages as the JavaScript reference implementation
- Exact: an int is an `Integer`, a float is a `Float`, an instant is a `Time` exact to the nanosecond, and a duration is an exact count of nanoseconds
- Canonical: `SOML.generate(value, canonical: true)` writes the one canonical form, so equal values give equal text
- Familiar: the API of `json`, with `parse`, `load_file`, `generate`, `symbolize_names:`, and `freeze:`
- Lossless: `SOML.format` and `SOML.edit` keep comments, member order, and spelling
- Safe: linear time and memory on every input, no stack overflow on deep input, and every document error is a `SOML::ParseError`
- Ractor-safe, with no dependencies

## Install

```sh
gem install soml-lang
```

Or in a `Gemfile`:

```ruby
gem 'soml-lang'
```

[On RubyGems](https://rubygems.org/gems/soml-lang). Requires Ruby 4.0 or later.

## Usage

```ruby
require 'soml'

config = SOML.parse(<<~SOML)
	# The edge service.
	name: 'api-gateway'
	replicas: 3
	timeout: 30.0
	grace: 1m30s
	deployed-at: 2026-09-19T14:00:00Z
	postgres: {host: 'db.internal'}
SOML
#=> {
# 	"name" => "api-gateway",
# 	"replicas" => 3,
# 	"timeout" => 30.0,
# 	"grace" => #<SOML::Duration 1m30s>,
# 	"deployed-at" => 2026-09-19 14:00:00 UTC,
# 	"postgres" => {"host" => "db.internal"}
# }

puts SOML.generate(config)
# name: 'api-gateway'
# replicas: 3
# timeout: 30.0
# grace: 1m30s
# deployed-at: 2026-09-19T14:00:00Z
# postgres: {
# 	host: 'db.internal'
# }
```

Read a file:

```ruby
config = SOML.load_file('config.soml', symbolize_names: true)
config[:postgres][:host]
#=> "db.internal"
```

Write a file in binary mode, so that Windows does not write CRLF, which SOML does not allow:

```ruby
File.binwrite('config.soml', SOML.generate(config))
```

## Types

| SOML | Ruby | `generate` also accepts |
|---|---|---|
| string | `String`, in UTF-8 | `Symbol`, and a `String` in any encoding that converts to UTF-8 |
| int | `Integer` | |
| float | `Float` | |
| bool | `true`, `false` | |
| null | `nil` | |
| instant | `Time`, in UTC | a `Time` with any offset |
| duration | [`SOML::Duration`](#somlduration) | |
| array | `Array` | |
| object | `Hash` with `String` keys, in document order, or `Symbol` keys with `symbolize_names: true` | `Symbol` keys |

`3` and `3.0` keep their types in both directions:

```ruby
SOML.parse("a: 3\nb: 3.0")
#=> {"a" => 3, "b" => 3.0}

SOML.generate({a: 3, b: 3.0})
#=> "a: 3\nb: 3.0\n"
```

> [!IMPORTANT]
> In Ruby, `3 == 3.0`, so `SOML.parse('a: 3') == SOML.parse('a: 3.0')` is true. Use `eql?` to also compare the types.

Two things always hold:

- `SOML.parse(SOML.generate(value))` equals `value`, for a value made of the types `parse` returns. (A `Time` comes back in UTC, a `Symbol` as a `String`, and `-0.0` as `0.0`.)
- `SOML.generate(SOML.parse(text), canonical: true)` is the canonical form of `text`.

An instant is a `Time` in UTC, because the offset is not part of its value:

```ruby
SOML.parse('a: 2026-09-19T14:00:00.123456789+02:00')['a']
#=> 2026-09-19 12:00:00.123456789 UTC
```

## API

### SOML.parse(source, symbolize_names: false, freeze: false)

Parse a document. Returns a `Hash` or an `Array`.

`source` is a `String`, or an object with `to_str`. A UTF-8, binary, or US-ASCII string is read as UTF-8. A string in another encoding, such as UTF-16, is converted to UTF-8 first, as `JSON.parse` does.

Raises `SOML::ParseError` when the document is not valid (including invalid UTF-8), `TypeError` when `source` is not a string, and `EncodingError` when it does not convert to UTF-8.

#### symbolize_names

Type: `Boolean`\
Default: `false`

Whether object keys are symbols rather than strings.

```ruby
SOML.parse('postgres: {host: "db"}', symbolize_names: true)
#=> {postgres: {host: "db"}}
```

#### freeze

Type: `Boolean`\
Default: `false`

Whether the result is deeply frozen, which also makes it shareable between ractors.

```ruby
config = SOML.parse("hosts: ['a', 'b']", freeze: true)
config['hosts'].frozen?
#=> true
Ractor.shareable?(config)
#=> true
```

### SOML.load_file(path, symbolize_names: false, freeze: false)

Read and parse a file. `path` is a `String`, or an object with `to_path`, such as a `Pathname`. The options are those of `SOML.parse`.

The file is read in binary mode, so that a text-mode conversion cannot hide a carriage return.

Raises `SOML::ParseError` when the document is not valid, and a `SystemCallError`, such as `Errno::ENOENT`, when the file cannot be read. The error names the file, so that an editor or a terminal can open it:

```ruby
SOML.load_file('config.soml')
# Raises SOML::ParseError: Duplicate key port at config.soml:3:1
```

### SOML.generate(value, canonical: false)

Write a `Hash` or an `Array` as SOML. Members keep the order of their hash, nesting uses braces and tabs, and the text ends with one line feed. Everything but the member order follows canonical form. Use `canonical: true` when the text is hashed, signed, or compared.

```ruby
SOML.generate({name: 'api', ports: [80, 443], description: 'The edge service'})
#=> "name: 'api'\nports: [\n\t80\n\t443\n]\ndescription: 'The edge service'\n"
```

Raises `SOML::GenerateError` for a value that cannot be written:

- a top-level value that is not a `Hash` or an `Array`
- `Float::NAN` (use `nil` for a missing value)
- an `Integer` outside the 64-bit range
- a `Time` outside the years 0001 to 9999 in UTC, or finer than a nanosecond
- a string or key with a carriage return, or that is not valid UTF-8 and does not convert to it
- a key that is not a `String` or a `Symbol`, and two keys that are the same string, such as `:a` and `'a'`
- a circular reference, and nesting deeper than 100 levels
- an object of any other class, such as a `Date` (write it as a string), a `Rational`, or an `ActiveSupport::Duration` (use a `SOML::Duration`). A `Struct`, `Data`, `Set`, or `Pathname` is not converted, because it would read back as another class. The message names the conversion to use, such as `to_h`.

The message says where the value is:

```ruby
SOML.generate({servers: [{ratio: Float::NAN}]})
# Raises SOML::GenerateError: NaN is not representable. Use nil for a missing value (at servers[0].ratio)
```

#### canonical

Type: `Boolean`\
Default: `false`

Whether to write canonical form, with the members of each object sorted by key. Two equal values give the same canonical text.

```ruby
SOML.generate({name: 'api', ports: [80, 443], description: 'The edge service'}, canonical: true)
#=> "description: 'The edge service'\nname: 'api'\nports: [\n\t80\n\t443\n]\n"
```

### SOML.format(source)

Format a document. Returns the document with its layout normalized, ending with one line feed.

The layout follows the [formatter](https://github.com/soml-lang/soml/blob/main/spec.md#formatting) in the specification: one tab per level, every member and item on its own line with no commas, and no trailing whitespace or runs of blank lines. A container on one line stays on one line, as in `ports: [80, 443]`. Put a line break anywhere inside it to split it. Comments, member order, block strings, and the spelling of every value stay as they are.

`source` is read as `SOML.parse` reads it, with the same errors.

```ruby
SOML.format('pool: {min: 2,   max: 16,} # Connections')
#=> "pool: {min: 2, max: 16} # Connections\n"

SOML.format("pool: {\nmin: 2, max: 16}")
#=> "pool: {\n\tmin: 2\n\tmax: 16\n}\n"
```

In detail:

- A block comment before a value on the same line, as in `1, /* note */ 2`, stays in front of that value.
- One space follows each `:`.
- A value on the line after its `key:` moves up to that line, unless a comment comes between them. Then it stays on its own line, one level deeper than the key.
- A block string begins on the line after its key, indented to that line. Its lines are not otherwise changed.
- There are no blank lines at the start of the file or directly inside brackets.

### SOML.edit(source, path, value) and SOML.edit(source, path, delete: true)

Change one value in a document, and keep everything else as it is written: comments, member order, layout, and spelling. For tools that update a config file, such as a dependency bumper or a `set` command.

The value at `path` is replaced, or added when it does not exist. `delete: true` removes it instead. Only the changed part of the text is rewritten, so a formatted document stays formatted.

```ruby
SOML.edit("name: 'api' # The service\nport: 8080\n", ['port'], 9090)
#=> "name: 'api' # The service\nport: 9090\n"

SOML.edit("postgres: {\n\thost: 'db'\n}\n", ['postgres', 'port'], 5432)
#=> "postgres: {\n\thost: 'db'\n\tport: 5432\n}\n"

SOML.edit("a: 1\nb: 2\n", ['a'], delete: true)
#=> "b: 2\n"
```

Read and write the file in binary mode, as for `SOML.generate`:

```ruby
File.binwrite('config.soml', SOML.edit(File.binread('config.soml'), ['postgres', 'port'], 5433))
```

- A new value is written as `SOML.generate` writes it (keeping member order), at the indentation of its line. So `0xFF` replaced by `255` is written `255`. In a one-line container, it is written on one line too, so `[1, 2]` with a new item `{a: 3}` becomes `[1, 2, {a: 3}]`.
- A new member goes after the last member of its object. Missing objects on the way are created.
- A new item can be added at the end of an array, at the index that is its length.
- A new member or item goes on its own line without a comma, after the comments that the one before it owns (see below). The commas of the others stay as they are. When something follows the one before it on the same line, such as the `}` of `{a: 1}`, it goes on that line after a comma, as in `{a: 1, b: 2}`. In an empty `[]` or `{}`, it goes on its own line, unless that container is inside a one-line container, so `a: [1, []]` becomes `a: [1, [2]]`.
- A removed member or item takes the comments it owns, which are the ones `SOML.format` keeps with it: the comments after it on its line (also after its comma), and the block comments before it on its line. So removing `2` from `[1, /* note */ 2]` gives `[1]`. A comment on a line of its own stays. Its lines are removed when nothing else is on them, including a line that a block comment after it continues onto. Removing every item of a container closes it up to `[]` or `{}`, unless a comment is left inside.
- A removed member or item takes its comma with it. When it is the last one without a comma after it, it takes the comma directly before it instead, so `[1, 2]` becomes `[1]`.
- Removing the only member of a document without braces leaves `{}`.

Comments inside a replaced or removed value are removed with it. In a layout that `SOML.format` never writes, such as an item after a closing block string delimiter on its line, a new item can be indented differently from its neighbors, but the document is always valid.

Removing a value that does not exist (a missing member, a missing object or array on the way, or an index at or past the end of its array) changes nothing, so it is safe to remove the same path twice. Use `SOML.edit(source, path, delete: true).b == source.b` to tell whether something was removed. The `.b` is needed because a source read in binary mode is not `==` to the UTF-8 result when it has non-ASCII characters.

The result is parsed before it is returned, so a bug in `SOML.edit` raises a `RuntimeError` rather than returning a broken document.

Raises:

- `SOML::ParseError` when `source` is not a valid document, the same as `SOML.parse`
- `TypeError` when `source` is not a string, when `path` is not a member node, a value node, or a non-empty array of keys and indexes, when it leads through a scalar, or when it has a key where an array is or an index where an object is
- `IndexError` when a value is set at an index past the end of its array, or at an index under a missing value
- `SOML::GenerateError` for a value or a key that `SOML.generate` cannot write, and when the change would nest more than 100 levels deep. Its path is the place in the document.
- `ArgumentError` when both a value and `delete: true` are given, or neither, or when `path` is the root node or a node that is not in `source`
- `EncodingError` as for `SOML.parse`

```ruby
SOML.edit('ports: [80]', ['ports', 5], 443)
# Raises IndexError: Cannot edit ports[5], because the array at ports has 1 item. Add an item at index 1
```

#### path

Type: `Array<String | Symbol | Integer>`, or a node from `SOML.parse_tree`

The keys and array indexes that lead to the value, such as `['servers', 0, 'port']`, or a member or value node from `SOML.parse_tree(source)` (see [Autofixes](#autofixes)).

#### value

The new value, of the types that `SOML.generate` accepts. `nil` writes `null`. Write a `Hash` with braces, as in `SOML.edit(source, ['pool'], {min: 2})`, because without them Ruby passes its members as keyword arguments.

#### delete

Type: `Boolean`\
Default: `false`

Remove the value at `path`, instead of setting it.

### SOML.bare_key?(key)

Whether a key can be written without quotes, as a bare key: one or more ASCII letters, digits, `_`, or `-`, in any order, so `404` and `-x` are bare keys too. `SOML.generate` writes such a key bare and quotes every other key.

```ruby
SOML.bare_key?('content-type')
#=> true

SOML.bare_key?('a.b')
#=> false
```

### SOML::Duration

A length of time, exact to the nanosecond, which is what a SOML duration such as `1h30m` holds. Ruby has no duration type of its own, and `ActiveSupport::Duration` has days and months, which are not a fixed length.

It is immutable, comparable, and usable as a hash key.

```ruby
timeout = SOML.parse('timeout: 1m30s')['timeout']
#=> #<SOML::Duration 1m30s>

timeout.nanoseconds
#=> 90000000000

sleep(timeout.to_f)
```

#### SOML::Duration.new(nanoseconds:)

Make a duration from a count of nanoseconds, which must be an `Integer` in the 64-bit range, about 292 years either way.

```ruby
SOML::Duration.new(nanoseconds: 1_500_000_000)
#=> #<SOML::Duration 1.5s>
```

#### SOML::Duration.parse(text)

Read a duration written as in a document. Raises `SOML::ParseError` when it is not one.

```ruby
SOML::Duration.parse('1.5h')
#=> #<SOML::Duration 1h30m>
```

#### SOML::Duration.from_seconds(seconds)

Make a duration from a number of seconds, the inverse of `#to_r`. The seconds are rounded to the nearest nanosecond, because a `Float` such as `0.1` is not exact. Raises `TypeError` when `seconds` is not a number, and `RangeError` when it is not finite or is outside the 64-bit range.

```ruby
SOML::Duration.from_seconds(90)
#=> #<SOML::Duration 1m30s>

SOML::Duration.from_seconds(0.1)
#=> #<SOML::Duration 0.1s>
```

#### #nanoseconds

The length in nanoseconds, an `Integer`.

#### #+(other) and #-(other)

The sum or the difference of two durations. A number has no unit, so `duration + 5` is a `TypeError`. Raises `RangeError` when the result is outside the 64-bit range.

```ruby
SOML::Duration.parse('1h') + SOML::Duration.parse('30m')
#=> #<SOML::Duration 1h30m>
```

#### #-@ and #abs

The opposite duration, and the duration without its sign.

#### #zero?, #positive?, and #negative?

Whether the length is zero, more than zero, or less than zero.

#### #to_r

The length in seconds, exactly, as a `Rational`.

#### #to_f

The length in seconds as a `Float`, for `sleep` and `Timeout.timeout`.

#### #to_s

The canonical spelling, such as `1h30m`, `1.5s`, `-0.25s`, or `0s`. So `90m` is written `1h30m`, and `-250ms` is written `-0.25s`.

### SOML::ParseError

Raised when the input is not a valid document. Subclass of `SOML::Error`, which is a `StandardError`.

The `message` is the reason and the position, on one line, so that it reads well in a log. The `detailed_message`, which Ruby shows for an uncaught error, also has a code frame:

```ruby
SOML.parse("name: 'api'\nreplicas: three")
# …: Unexpected “three”. A string value must be quoted, as in 'three' at line 2, column 11 (SOML::ParseError)
#
#   1 | name: 'api'
# > 2 | replicas: three
#     |           ^
```

#### reason

What is wrong, without the position.

#### line

The 1-based line.

#### column

The 1-based column, counted in characters.

#### offset

The 0-based character index in the source read as UTF-8, so for a UTF-8 source, `source[error.offset]` is the character at the error.

#### path

The file, when the document was read by `SOML.load_file`, and otherwise `nil`.

#### code_frame

Up to three lines ending at the error, with a caret under the position. A long line is clipped around the position, and characters that a terminal would act on are replaced.

### SOML::GenerateError

Raised by `SOML.generate` for a value that cannot be written. Subclass of `SOML::Error`.

#### reason

What is wrong, without the location.

#### path

The keys and indexes that lead to the value, such as `["servers", 0, "ratio"]`, or an empty array for the top-level value.

## Recipes

### Hash a config

Equal values give equal canonical text, so hash it to compare, cache, or sign a config. Comments, the order of members, and the spelling of values do not change the hash:

```ruby
require 'digest'

Digest::SHA256.hexdigest(SOML.generate(SOML.parse("b: 1\na: 0x10 # Note."), canonical: true))
#=> the same as for SOML.parse("a: 16\nb: 1")
```

### Compare two configs

Canonical form has one sorted member on each line, so a line diff shows every change, including a change of type, which `==` misses, because `3 == 3.0` in Ruby:

```ruby
before = SOML.generate(SOML.parse("a: 3\nb: 1"), canonical: true)
after = SOML.generate(SOML.parse("a: 3.0\nb: 1"), canonical: true)
before.lines - after.lines
#=> ["a: 3\n"]
```

### Check the shape of a config

Pattern matching checks the type of each member that a program reads, and binds it to a variable, with no schema library. A config that does not match raises an error that names the member:

```ruby
config = SOML.load_file('config.soml', symbolize_names: true)
config => {name: String => name, port: Integer => port, timeout: SOML::Duration => timeout}
```

For `port: '8080'`, this raises `NoMatchingPatternError` with `Integer === "8080" does not return true`, and without a `port`, it raises `NoMatchingPatternKeyError` with `key not found: :port`.

### Read a config in Rails

`config_for` reads YAML only, so read the file in an initializer. With one top-level object for each environment, this works as `config_for` does:

```
# config/payments.soml
production: {
	timeout: 30s
	endpoint: 'https://payments.example.com'
}
development: {
	timeout: 5m
	endpoint: 'http://localhost:4000'
}
```

```ruby
# config/initializers/payments.rb
Rails.application.config.x.payments = SOML.load_file(Rails.root.join('config/payments.soml'), symbolize_names: true, freeze: true).fetch(Rails.env.to_sym)
```

An instant is a `Time` in UTC, and `in_time_zone` gives it in the zone of the app. A duration is a `SOML::Duration`, and `to_r.seconds` gives an `ActiveSupport::Duration` of the same exact length:

```ruby
Rails.configuration.x.payments[:timeout].to_r.seconds == 30.seconds
#=> true
```

To write an `ActiveSupport::Duration`, convert it with `SOML::Duration.from_seconds`:

```ruby
SOML.generate({timeout: SOML::Duration.from_seconds(5.minutes.to_r)})
#=> "timeout: 5m\n"
```

## Benchmark

CPU time to read and write the shared [benchmark fixtures](https://github.com/soml-lang/soml/blob/main/benchmark/readme.md), which hold the same data in SOML, JSON, and TOML, on an Apple M-series machine with Ruby 4.0 and YJIT. The numbers are rough. Lower is better.

| | this gem | `toml-rb` | `json` | `oj` |
|---|---|---|---|---|
| Read `service` (3 KB) | 78 µs | 174 µs | 10 µs | 11 µs |
| Read `platform` (35 KB) | 0.61 ms | 1.2 ms | 0.10 ms | 0.07 ms |
| Read `earthquakes` (733 KB) | 14 ms | 51 ms | 2.2 ms | 2.8 ms |
| Write `service` | 51 µs | 105 µs | 8 µs | 8 µs |
| Write `platform` | 0.34 ms | 0.65 ms | 0.06 ms | 0.03 ms |
| Write `earthquakes` | 15 ms | 26 ms | 2.1 ms | 3.2 ms |

`toml-rb` is pure Ruby, like this gem, and `json` and `oj` are C extensions. The script also compares `tomlib`, `perfect_toml`, and `tomlrb`, and times `SOML.format`, `SOML.edit`, and `SOML.parse_tree` on each fixture:

```sh
bundle config set --local with benchmark
bundle install
bundle exec ruby --yjit bench/benchmark.rb
```

## Syntax tree

`SOML.parse_tree(source)` returns a deeply frozen `SOML::Tree` with `source` (a UTF-8 copy), `body` (an object or array), `tokens`, and `comments`. It accepts the same inputs and raises the same errors as `SOML.parse`, without freezing the caller's string. Only valid documents are supported; there is no recovery from incomplete editor input.

```ruby
tree = SOML.parse_tree('port: 0x1F90 # Default')
node = tree.body.members.first.value

node.kind #=> :integer
node.value #=> 8080
node.radix #=> 16
tree.source.byteslice(node.start...node.finish) #=> "0x1F90"
tree.position(node.start) #=> [1, 7]
```

Every node, token, and comment has `start` and exclusive `finish` UTF-8 byte offsets into `tree.source`. Use `byteslice` to read spans. Collections include their brackets; a bare root object spans its first key through its last value. `position(byte_offset)` returns one-based `[line, column]`, counting Unicode characters, including tabs as one character. It accepts character boundaries through EOF, raising `TypeError` for non-integers and `ArgumentError` for invalid offsets. Unlike tree spans, `ParseError#offset` counts characters.

`each_node` yields the body and its descendants in source order, parents before children and member keys before values; without a block it returns an Enumerator. Tokens and comments are separate, each in source order. Node constructors are internal.

| Class under `SOML::Tree` | `type` | Fields besides `start` and `finish` |
|---|---|---|
| `ObjectNode` | `:object` | `members`, `braced` |
| `ArrayNode` | `:array` | `elements` |
| `MemberNode` | `:member` | `key`, `value` (a node) |
| `KeyNode` | `:key` | `value` (decoded string), `style` (`:bare`, `:literal`, or `:escaped`) |
| `ScalarNode` | `:scalar` | `kind`, `value` (decoded), `block`, `style`, `radix` |
| `Comment` | `:line` or `:block` | `value` (text without delimiters) |
| `Token` | See below | `value` (original source text) |

Scalar kinds are `:string`, `:integer`, `:float`, `:boolean`, `:null`, `:instant`, and `:duration`, with the same Ruby values as `SOML.parse`. Strings have `style: :literal` or `:escaped` and a `block` boolean; integers have `radix: 2`, `8`, `10`, or `16`. Otherwise, `style` and `radix` are `nil`, and `block` is `false`.

### Syntax highlighting

Token types are `:punctuator` (`{}[]:,`), `:bare_key`, `:string`, `:integer`, `:float`, `:keyword` (`true`, `false`, `null`), `:instant`, and `:duration`. Quoted keys and whole block strings are string tokens; escapes stay within strings. Infinities are floats. Use key nodes to distinguish quoted keys from string values.

```ruby
(tree.tokens + tree.comments).sort_by(&:start).each do |token|
	text = tree.source.byteslice(token.start...token.finish)
	# Highlight text using token.type, preserving whitespace between spans.
end
```

Tokens never overlap and exclude whitespace and comments. When rendering HTML, escape all source text, including comments and gaps.

### Autofixes

`SOML.edit` accepts a member or non-root value node in place of a path, using its existing comment and layout rules. Members select their value for replacement and the whole member for deletion. Keys, tokens, comments, and the root collection are not accepted.

```ruby
source = "port: 0x1F90 # Default\n"
node = SOML.parse_tree(source).body.members.first.value
SOML.edit(source, node, 9090)
#=> "port: 9090 # Default\n"
```

Nodes must come from the same source text. Reparse after editing before selecting another node. For spelling fixes, apply non-overlapping span replacements from the end backwards to `tree.source.b`, restore UTF-8 with `force_encoding(Encoding::UTF_8)`, then validate with `SOML.parse`.

## Limits

- **Nesting is limited to 100 levels**, as the specification requires, in reading and in writing. Every array and object is one level, including the document's own collection.
- **The gem name.** The gem is [`soml-lang`](https://rubygems.org/gems/soml-lang), because `soml` on RubyGems is an unrelated format. It also defines `module SOML`, so the two gems cannot be loaded together.

## Development

```sh
bundle install
bundle exec rake
```

`SOML_EXAMPLES=10000 bundle exec rake` runs the property tests with more examples, and `SOML_SEED=1234` repeats a run.

The fixtures in [`bench/fixtures`](bench/fixtures) are a copy of the shared ones in the [`soml`](https://github.com/soml-lang/soml/tree/main/benchmark) spec repository. To update them, check out `soml` next to this repository and run `rsync --archive --delete ../soml/benchmark/ bench/fixtures/`.

The conformance suite in [`test/conformance`](test/conformance) is a copy of the one in the [`soml`](https://github.com/soml-lang/soml/tree/main/conformance) spec repository. To update it, check out `soml` next to this repository and run `../soml/sync-conformance.sh test/conformance`.
