# frozen_string_literal: true

require 'retcon'

RSpec.describe Retcon do
  it 'has a version' do
    expect(Retcon::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end
end
