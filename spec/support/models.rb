# frozen_string_literal: true

class Venue < ActiveRecord::Base
  include Retcon::Model

  has_many :events, dependent: :destroy
  validates :name, presence: true

  versioned do
    scope(&:audience)
  end
end

class Event < ActiveRecord::Base
  include Retcon::Model

  belongs_to :venue, optional: true
  validates :name, presence: true

  # A side effect that must not run when Retcon replays history.
  after_save { self.class.saves << id unless Retcon.replaying? }

  def self.saves = @saves ||= []
end

class Link < ActiveRecord::Base
  include Retcon::Edge

  retcon_triple subject: %i[subject_type subject_id], predicate: :predicate, object: %i[object_type object_id]
end
