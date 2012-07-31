module Scrapify
  module Base
    HTTP_CACHE_HEADERS_TO_RETURN = %w(Cache-Control Last-Modified Age ETag)
    def self.included(klass)
      klass.extend ClassMethods
      klass.cattr_accessor :url, :doc, :attribute_names, :type
      klass.instance_eval { attr_reader :attributes }
    end

    def initialize(attributes)
      @attributes = attributes
    end

    def method_missing(method, *args, &block)
      @attributes[method] || super
    end

    def to_json(*args)
      @attributes.to_json(*args)
    end

    module ClassMethods
      def html(url)
        self.url = url
        self.type = :html
        define_finders
      end

      def xml(url)
        self.url = url
        self.type = :xml
        define_finders
      end

      def attribute(name, options={}, &block)
        add_attribute(name)
        options = options.symbolize_keys
        parser = options[:xpath] ? :xpath : :css
        selector = options[parser]
        matcher = /#{options[:regex]}/ if options[:regex]
        to_array = options[:array]
        define_singleton_method "#{name}_values" do
          self.doc ||= parse_doc
          self.doc.send(parser, selector).map do |element|
            if block
              yield element
            else
              content = element.content
              if matcher
                match_data = content.scan(matcher).map &:first
                options[:array] ? match_data : match_data.first
              else
                content.strip
              end
            end
          end
        end
      end

      def key(attribute)
        define_find_by_id attribute
        define_count attribute
      end

      def http_cache_header
        http_header.select do |(k, v)|
          HTTP_CACHE_HEADERS_TO_RETURN.map(&:upcase).include?(k.upcase)
        end
      end

      private

      def add_attribute(name)
        self.attribute_names ||= [] 
        self.attribute_names << name
      end

      def parse_doc
        doc = case type
              when :html
                Nokogiri::HTML(html_content)
              when :xml
                Nokogiri::XML(html_content)
              end
        doc.css('br').each {|br| br.replace("\n")} if type == :html
        doc
      end

      def html_content
        http_response.body
      end

      def http_response
        @http_response ||= Net::HTTP.get_response URI(url)
      end

      def http_header
        http_response.header.to_hash.each_with_object({}) do |(k,v), hash|
          hash[k] = v.first
        end
      end

      def define_finders
        define_singleton_method :all do
          count.times.map do |index|
            find_by_index index
          end
        end

        define_singleton_method :first do
          find_by_index 0
        end

        define_singleton_method :last do
          find_by_index count - 1
        end

        define_singleton_method :find_by_index do |index|
          return if index.nil? or index < 0
          attributes = Hash[attribute_names.map {|attribute| [attribute, send("#{attribute}_values")[index]]}]
          self.new(attributes)
        end

        define_singleton_method :where do |conditions = {}|
          raise Scrapify::AttributeDoesNotExist.new(conditions.keys - attribute_names) unless conditions.keys.all?{|key| attribute_names.include?(key) }
          indices = conditions.collect do |attribute, value|
            send("#{attribute}_values").each_with_index.find_all{|attr_val, index| attr_val == value}.collect(&:last)
          end
          common_indices = indices.reduce {|a, b| a & b}
          common_indices.collect{|index| find_by_index(index)}
        end
      end

      def define_count(key_attribute)
        define_singleton_method :count do
          send("#{key_attribute}_values").size
        end
      end

      def define_find_by_id(key_attribute)
        define_singleton_method :find do |key_value|
          index = send("#{key_attribute}_values").index(key_value)
          find_by_index index
        end
      end
    end
  end
end
