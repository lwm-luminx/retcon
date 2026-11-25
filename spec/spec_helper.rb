# frozen_string_literal: true

# RETCON_DATABASE_URL names a PostgreSQL database (15 or later) the specs make their tables in.
require 'simplecov'
SimpleCov.start do
  skip '/spec/'
  enable_coverage :branch
  minimum_coverage line: 85
end

require 'retcon'

ActiveRecord::Base.establish_connection(ENV.fetch('RETCON_DATABASE_URL', 'postgres:///retcon_test'))
ActiveRecord::Migration.verbose = false
require_relative 'support/schema'
require_relative 'support/models'

RSpec.configure do |config|
  config.before(:suite) { RetconSpec::Schema.create! }
  config.after(:suite) { RetconSpec::Schema.drop! }
  config.around do |example|
    ActiveRecord::Base.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  end
  config.disable_monkey_patching!
  config.order = :random
end
