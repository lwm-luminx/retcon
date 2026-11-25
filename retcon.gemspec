# frozen_string_literal: true

require_relative 'lib/retcon/version'

Gem::Specification.new do |spec|
  spec.name = 'retcon'
  spec.version = Retcon::VERSION
  spec.authors = ['Love Wins Media, Inc.']
  spec.summary = 'VCS-style history, proposals and reverts for Active Record'
  spec.description = 'Field-level version history for Active Record models, kept in per-table history tables with ' \
                     'live tables as a fast projection: changesets with full attribution, proposals reviewed before ' \
                     'they apply, field-level conflicts, tombstones instead of deletes, reverts of one actor\'s ' \
                     'changes that keep later good work, and redaction. Early release: the name is reserved and ' \
                     'the design is in review.'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.3'
  spec.files = Dir['lib/**/*', 'README.md', 'CHANGELOG.md', 'LICENSE.txt']
  spec.require_paths = ['lib']
  spec.metadata['rubygems_mfa_required'] = 'true'
  spec.homepage = 'https://github.com/lwm-luminx/retcon'
  spec.metadata['source_code_uri'] = 'https://github.com/lwm-luminx/retcon'
  spec.metadata['changelog_uri'] = 'https://github.com/lwm-luminx/retcon/blob/main/CHANGELOG.md'
  spec.metadata['bug_tracker_uri'] = 'https://github.com/lwm-luminx/retcon/issues'
end
