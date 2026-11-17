# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require_relative "../errors"
require_relative "../state/records"

module Harness
  module UI
    # The app's look, chosen in Settings · Appearance: the system's dark or light setting, or always one of them, and
    # the colours of each look. Only colours: the font and the layout are fixed. The choice lives in appearance.json
    # next to config.json and reaches the page as /theme.css, a stylesheet built here from validated hex values only,
    # so the strict CSP (style-src 'self') holds and nothing the user types becomes CSS syntax.
    module Appearance
      MODES = ["system", "dark", "light"].freeze
      LOOKS = %w[dark light].freeze
      # The core colours of a look; app.css derives every other shade from these.
      COLORS = %w[bg surface text accent success warn danger].freeze
      HEX = /\A#\h{6}\z/
      FILE = "appearance.json"
      # Text on an accent-coloured button: whichever of these reads better on the accent.
      DARK_INK = "#16151c"
      LIGHT_INK = "#ffffff"

      # @!attribute mode [String] one of MODES
      # @!attribute dark [Hash{String=>String}] colours that replace the dark look's defaults (may be empty)
      # @!attribute light [Hash{String=>String}] colours that replace the light look's defaults (may be empty)
      Look = Data.define(:mode, :dark, :light) do
        # @return [Hash] the JSON shape, as saved and as the page reads it
        def to_json_hash = { "mode" => mode, "dark" => dark, "light" => light }
      end

      DEFAULT = Look.new(mode: "system", dark: {}.freeze, light: {}.freeze)

      # @param data [Object] parsed JSON
      # @return [Look]
      # @raise [ParseError] naming the first field that is wrong
      def self.parse(data)
        raise ParseError, "appearance: expected an object" unless data.is_a?(Hash)

        unknown = data.keys - %w[mode dark light]
        raise ParseError, "appearance.#{unknown.first.to_s[0, 40]}: unknown field" unless unknown.empty?

        mode = data.fetch("mode", "system")
        raise ParseError, "appearance.mode: expected one of #{MODES.join(', ')}, got #{mode.inspect[0, 40]}" unless MODES.include?(mode)

        looks = LOOKS.to_h { |name| [name.to_sym, colors(data[name], name)] }
        Look.new(mode: mode, **looks)
      end

      # @param value [Object]
      # @param name [String] "dark" or "light", for the message
      # @return [Hash{String=>String}] frozen, lower-case hex values
      # @raise [ParseError]
      def self.colors(value, name)
        return {}.freeze if value.nil?
        raise ParseError, "appearance.#{name}: expected an object of colours" unless value.is_a?(Hash)

        value.to_h do |key, hex|
          raise ParseError, "appearance.#{name}.#{key.to_s[0, 40]}: unknown colour (#{COLORS.join(', ')})" unless COLORS.include?(key)
          raise ParseError, "appearance.#{name}.#{key}: expected a colour like #9a8cf2" unless hex.is_a?(String) && hex.match?(HEX)

          [key, hex.downcase]
        end.freeze
      end

      # @param home [String] the folder of config.json
      # @return [Look] the saved choice, or DEFAULT when there is none or the file is unreadable
      def self.load(home)
        path = File.join(home, FILE)
        return DEFAULT unless File.file?(path)

        parse(JSON.parse(File.read(path, encoding: "UTF-8")))
      rescue JSON::ParserError, ParseError, SystemCallError
        DEFAULT
      end

      # @param home [String]
      # @param data [Object] parsed JSON from the page
      # @return [Look] what was saved
      # @raise [ParseError] when data is not a valid look; nothing is written then
      def self.save(home, data)
        look = parse(data)
        State.write_json(File.join(home, FILE), look.to_json_hash)
        look
      end

      # /theme.css: the user's colours over app.css's defaults, with the same selectors app.css uses for each look,
      # so a dark colour never leaks into the light look.
      # @param look [Look]
      # @return [String]
      def self.css(look)
        out = +"/* vb-harness: colours from Settings · Appearance (#{FILE}) */\n"
        out << block(":root", look.dark) unless look.dark.empty?
        unless look.light.empty?
          out << "@media (prefers-color-scheme: light) {\n#{block(':root:not([data-mode="dark"])', look.light)}}\n"
          out << block(':root[data-mode="light"]', look.light)
        end
        out
      end

      # @return [String]
      def self.block(selector, colors)
        lines = colors.map { |key, hex| "  --#{key}: #{hex};" }
        lines << "  --on-accent: #{on_accent(colors['accent'])};" if colors["accent"]
        "#{selector} {\n#{lines.join("\n")}\n}\n"
      end

      # @param hex [String] "#rrggbb"
      # @return [String] DARK_INK or LIGHT_INK, whichever contrasts more with hex
      def self.on_accent(hex)
        l = luminance(hex)
        (l + 0.05) / (luminance(DARK_INK) + 0.05) >= (luminance(LIGHT_INK) + 0.05) / (l + 0.05) ? DARK_INK : LIGHT_INK
      end

      # WCAG relative luminance.
      # @param hex [String] "#rrggbb"
      # @return [Float]
      def self.luminance(hex)
        r, g, b = hex.delete_prefix("#").scan(/../).map do |c|
          v = c.to_i(16) / 255.0
          v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055)**2.4
        end
        (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
      end
      private_class_method :block, :colors
    end
  end
end
