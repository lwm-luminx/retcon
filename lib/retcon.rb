# frozen_string_literal: true

require 'retcon/version'

# VCS-style history for Active Record: field-level versions, changesets, proposals and reverts, with live tables kept
# as a fast projection of history. This release reserves the name; nothing is implemented yet. See README.md.
module Retcon
  class Error < StandardError; end
end
