# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require "net/http"
require "uri"
require_relative "../errors"

module Harness
  module Model
    # JSON over HTTP for OpenAI-compatible servers. Connection problems become ModelUnavailableError;
    # HTTP error statuses are returned for the caller to classify. Injected so tests can replace it.
    class Http
      Response = Data.define(:status, :body, :json) do
        # @return [Boolean]
        def ok?
          status.between?(200, 299)
        end

        # @return [String] the server's error message, or the start of the body
        def error_text
          msg = json.is_a?(Hash) ? json["error"] : nil
          msg = msg["message"] if msg.is_a?(Hash)
          (msg.is_a?(String) ? msg : body.to_s)[0, 2000]
        end
      end

      NETWORK_ERRORS = [IOError, SystemCallError, SocketError, Timeout::Error, EOFError, Net::HTTPBadResponse].freeze

      # @param open_timeout [Numeric] seconds to connect
      def initialize(open_timeout: 5)
        @open_timeout = open_timeout
      end

      # @param url [String]
      # @param headers [Hash{String=>String}]
      # @param timeout [Numeric] read timeout in seconds
      # @return [Response]
      # @raise [ModelUnavailableError] on connection failure or timeout
      def get(url, headers: {}, timeout: 10)
        request(Net::HTTP::Get.new(URI(url)), url, headers, timeout)
      end

      # @param url [String]
      # @param payload [Hash] sent as JSON
      # @param headers [Hash{String=>String}]
      # @param timeout [Numeric] read timeout in seconds
      # @return [Response]
      # @raise [ModelUnavailableError] on connection failure or timeout
      def post(url, payload, headers: {}, timeout: 900)
        req = Net::HTTP::Post.new(URI(url))
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(payload)
        request(req, url, headers, timeout)
      end

      private

      # @return [Response]
      def request(req, url, headers, timeout)
        uri = URI(url)
        headers.each { |k, v| req[k] = v }
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: @open_timeout,
                                                  read_timeout: timeout, write_timeout: timeout) do |http|
          http.request(req)
        end
        body = res.body.to_s.dup.force_encoding(Encoding::UTF_8).scrub
        Response.new(status: res.code.to_i, body: body, json: parse_json(body))
      rescue *NETWORK_ERRORS => e
        kind = e.is_a?(Timeout::Error) ? "timed out" : "failed (#{e.class.name.split('::').last})"
        raise ModelUnavailableError, "request to #{uri.scheme}://#{uri.host}:#{uri.port}#{uri.path} #{kind}"
      end

      # @return [Object, nil]
      def parse_json(body)
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
