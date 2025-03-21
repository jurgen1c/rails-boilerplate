# frozen_string_literal: true

module StyleVariants
  extend ActiveSupport::Concern
  # Example
  # style do
  #   base {
  #     %w[
  #       font-medium bg-blue-500 text-white rounded-full
  #     ]
  #   }
  #   variants {
  #     color {
  #       primary { %w[bg-blue-500 text-white] }
  #       secondary { %w[bg-purple-500 text-white] }
  #     }
  #     size {
  #       sm { "text-sm" }
  #       md { "text-base" }
  #       lg { "px-4 py-3 text-lg" }
  #     }
  #     disabled {
  #       yes { "opacity-75" }
  #     }
  #   }
  #   defaults { {size: :md, color: :primary} }
  # end

  class VariantBuilder
    attr_reader :unwrap_blocks

    def initialize(unwrap_blocks = true)
      @unwrap_blocks = unwrap_blocks
      @variants = {}
    end

    def build(&)
      instance_eval(&)
      @variants
    end

    def respond_to_missing?(name, include_private = false)
      true
    end

    def method_missing(name, &block)
      return super unless block_given?

      @variants[name] = if unwrap_blocks
                          VariantBuilder.new(false).build(&block)
                        else
                          block
                        end
    end
  end

  class StyleSet
    def initialize(&init_block)
      @base_block = nil
      @defaults = {}
      @variants = {}
      @compounds = {}

      instance_eval(&init_block) if init_block
    end

    def base(&block)
      @base_block = block
    end

    def defaults(&)
      @defaults = yield.freeze
    end

    def variants(&)
      @variants = VariantBuilder.new(true).build(&)
    end

    def compound(**variants, &block)
      @compounds[variants] = block
    end

    def compile(**variants)
      acc = Array(@base_block&.call || [])

      config = @defaults.merge(variants.compact)

      config.each do |variant, value|
        value = cast_value(value)
        variant = @variants.dig(variant, value) || next
        styles = variant.is_a?(::Proc) ? variant.call(**config) : variant
        acc.concat(Array(styles))
      end

      @compounds.each do |compound, value|
        next unless compound.all? { |k, v| config[k] == v }

        styles = value.is_a?(::Proc) ? value.call(**config) : value
        acc.concat(Array(styles))
      end

      acc
    end

    def dup
      copy = super
      copy.instance_variable_set(:@defaults, @defaults.dup)
      copy.instance_variable_set(:@variants, @variants.dup)
      copy.instance_variable_set(:@compounds, @compounds.dup)
      copy
    end

    private

    def cast_value(val)
      case val
      when true then :yes
      when false then :no
      else
        val
      end
    end
  end

  class StyleConfig # :nodoc:
    DEFAULT_POST_PROCESSOR = ->(compiled) { compiled.join(' ') }

    attr_reader :postprocessor

    def initialize
      @styles = {}
      @postprocessor = DEFAULT_POST_PROCESSOR
    end

    def define(name, &)
      styles[name] = StyleSet.new(&)
    end

    def compile(name, **variants)
      styles[name]&.compile(**variants).then do |compiled|
        next unless compiled

        postprocess(compiled)
      end
    end

    # Allow defining a custom postprocessor
    def postprocess_with(callable = nil, &block)
      @postprocessor = callable || block
    end

    def dup
      copy = super
      copy.instance_variable_set(:@styles, @styles.dup)
      copy
    end

    private

    attr_reader :styles

    def postprocess(compiled) = postprocessor.call(compiled)
  end

  def self.included(base)
    base.extend ClassMethods
  end

  module ClassMethods
    # Returns the name of the default style set based on the class name:
    #  MyComponent::Component => my_component
    #  Namespaced::MyComponent => my_component
    def default_style_name
      @default_style_name ||= name.demodulize.sub(/(::Component|Component)$/, '').underscore.presence || 'component'
    end

    def style(name = default_style_name, &)
      style_config.define(name.to_sym, &)
    end

    def style_config
      @style_config ||=
        if superclass.respond_to?(:style_config)
          superclass.style_config.dup
        else
          StyleConfig.new
        end
    end
  end

  def style(name = self.class.default_style_name, **variants)
    self.class.style_config.compile(name.to_sym, **variants)
  end
end
