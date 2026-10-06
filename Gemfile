# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

gem 'minitest', '>= 5.25'
gem 'rake', '>= 13'

# The formats that `bench/benchmark.rb` compares with. Install them with `bundle config set --local with benchmark && bundle install`.
group :benchmark, optional: true do
	gem 'oj'
	gem 'perfect_toml'
	gem 'toml-rb'
	gem 'tomlib'
	gem 'tomlrb'

	# A bundled gem since Ruby 3.3, which tomlrb needs.
	gem 'racc'
end
