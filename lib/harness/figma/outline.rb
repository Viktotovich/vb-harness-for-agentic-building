# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"

module Harness
  module Figma
    # A Figma node tree as short indented text: what a model needs to build it (structure, sizes, spacing, colours,
    # type and wording) without the raw JSON, which is many times longer and mostly drawing data.
    module Outline
      MAX_TEXT = 200
      # Their children are drawing detail, not structure.
      LEAVES = %w[VECTOR BOOLEAN_OPERATION LINE ELLIPSE STAR REGULAR_POLYGON].freeze
      PADDING = %w[paddingTop paddingRight paddingBottom paddingLeft].freeze

      # @param node [Hash] a node from the Figma API
      # @param depth [Integer] indentation level
      # @return [Array<String>] one line per visible node
      def self.lines(node, depth = 0)
        return [] unless node.is_a?(Hash) && node["visible"] != false

        own = "#{'  ' * depth}#{describe(node)}"
        return [own] if LEAVES.include?(node["type"]) || !node["children"].is_a?(Array)

        [own, *node["children"].flat_map { |child| lines(child, depth + 1) }]
      end

      # @return [String]
      def self.describe(node)
        kind = node["type"].to_s.tr("_", " ").capitalize
        head = "#{kind} #{quoted(node['name'])}#{size(node['absoluteBoundingBox'])}".strip
        details = [text(node), layout(node), paint("fill", node["fills"]), stroke(node), radius(node), opacity(node)].flatten.compact
        details.empty? ? head : "#{head}: #{details.join(', ')}"
      end
      private_class_method :describe

      # @return [String] JSON quoting keeps a newline in a layer's text from starting a line of the outline
      def self.quoted(text)
        s = text.to_s
        JSON.generate(s.size > MAX_TEXT ? "#{s[0, MAX_TEXT]}..." : s)
      end
      private_class_method :quoted

      # @return [String]
      def self.size(box)
        return "" unless box.is_a?(Hash) && box["width"].is_a?(Numeric) && box["height"].is_a?(Numeric)

        " #{number(box['width'])}x#{number(box['height'])}"
      end
      private_class_method :size

      # @return [Array<String, nil>, nil]
      def self.text(node)
        return nil unless node["type"] == "TEXT"

        style = node["style"].is_a?(Hash) ? node["style"] : {}
        size = style["fontSize"].is_a?(Numeric) ? "#{number(style['fontSize'])}px" : nil
        font = [style["fontFamily"], style["fontWeight"], size].compact.join(" ")
        height = style["lineHeightPx"].is_a?(Numeric) ? "line height #{number(style['lineHeightPx'])}" : nil
        align = style["textAlignHorizontal"]
        [quoted(node["characters"]), (font unless font.empty?), height, (align && align != "LEFT" ? "align #{align.to_s.downcase}" : nil)]
      end
      private_class_method :text

      # @return [Array<String, nil>, nil]
      def self.layout(node)
        mode = node["layoutMode"]
        return nil unless %w[HORIZONTAL VERTICAL].include?(mode)

        pads = PADDING.map { |key| node[key].is_a?(Numeric) ? node[key] : 0 }
        [mode.downcase, (node["itemSpacing"].is_a?(Numeric) ? "gap #{number(node['itemSpacing'])}" : nil),
         (pads.any?(&:positive?) ? "padding #{pads.map { |p| number(p) }.join(' ')}" : nil)]
      end
      private_class_method :layout

      # @return [String, nil] the top visible paint, the one that shows
      def self.paint(label, paints)
        top = (paints.is_a?(Array) ? paints : []).select { |p| p.is_a?(Hash) && p["visible"] != false }.last
        return nil unless top

        case top["type"]
        when "SOLID" then colour(top) && "#{label} #{colour(top)}"
        when "IMAGE" then "#{label} image"
        else "#{label} #{top['type'].to_s.downcase.tr('_', ' ')}"
        end
      end
      private_class_method :paint

      # @return [String, nil] #RRGGBB, with its opacity when it is not solid
      def self.colour(paint)
        c = paint["color"]
        return nil unless c.is_a?(Hash) && %w[r g b].all? { |k| c[k].is_a?(Numeric) }

        hex = %w[r g b].map { |k| format("%02X", (c[k] * 255).round.clamp(0, 255)) }.join
        alpha = (c["a"].is_a?(Numeric) ? c["a"] : 1) * (paint["opacity"].is_a?(Numeric) ? paint["opacity"] : 1)
        alpha < 1 ? "##{hex} at #{(alpha * 100).round}%" : "##{hex}"
      end
      private_class_method :colour

      # @return [String, nil]
      def self.stroke(node)
        line = paint("stroke", node["strokes"])
        line && node["strokeWeight"].is_a?(Numeric) ? "#{line} #{number(node['strokeWeight'])}px" : line
      end
      private_class_method :stroke

      # @return [String, nil]
      def self.radius(node)
        r = node["cornerRadius"]
        r.is_a?(Numeric) && r.positive? ? "radius #{number(r)}" : nil
      end
      private_class_method :radius

      # @return [String, nil]
      def self.opacity(node)
        o = node["opacity"]
        o.is_a?(Numeric) && o < 1 ? "opacity #{(o * 100).round}%" : nil
      end
      private_class_method :opacity

      # @return [String] 24, not 24.0
      def self.number(value)
        rounded = value.round(2)
        rounded == rounded.to_i ? rounded.to_i.to_s : rounded.to_s
      end
      private_class_method :number
    end
  end
end
