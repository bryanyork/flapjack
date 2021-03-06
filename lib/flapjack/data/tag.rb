#!/usr/bin/env ruby

require 'zermelo/records/redis_record'

require 'flapjack/data/validators/id_validator'

require 'flapjack/data/check'
require 'flapjack/data/rule'

module Flapjack
  module Data
    class Tag

      include Zermelo::Records::RedisRecord
      include ActiveModel::Serializers::JSON
      self.include_root_in_json = false

      define_attributes :name => :string

      has_and_belongs_to_many :checks,
        :class_name => 'Flapjack::Data::Check', :inverse_of => :tags,
        :after_add => :changed_checks, :after_remove => :changed_checks,
        :related_class_names => ['Flapjack::Data::Rule', 'Flapjack::Data::Route']

      def changed_checks(*cs)
        cs.each {|check| check.recalculate_routes }
      end

      has_and_belongs_to_many :rules,
        :class_name => 'Flapjack::Data::Rule', :inverse_of => :tags,
        :after_add => :changed_rules, :after_remove => :changed_rules,
        :related_class_names => ['Flapjack::Data::Check', 'Flapjack::Data::Route']

      def changed_rules(*rs)
        rs.each {|rule| rule.recalculate_routes }
      end

      unique_index_by :name

      # can't use before_validation, as the id's autogenerated by then
      alias_method :original_save, :save
      def save
        self.id = self.name if self.id.nil?
        original_save
      end

      # name must == id
      validates :name, :presence => true,
        :inclusion => { :in => proc {|t| [t.id] }},
        :format => /\A[a-z0-9\-_\.\|]+\z/i

      before_update :update_allowed?
      def update_allowed?
        !self.changed.include?('name')
      end

      def self.jsonapi_id
        :name
      end

      def self.jsonapi_attributes
        [:name]
      end

      def self.jsonapi_singular_associations
        []
      end

      def self.jsonapi_multiple_associations
        [:checks, :rules]
      end
    end
  end
end
