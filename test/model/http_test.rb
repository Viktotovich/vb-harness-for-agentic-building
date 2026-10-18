# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../test_helper"
require "socket"

class HttpTest < Minitest::Test
  # A field report saw the model server busy after a run had ended. On a timeout the client closes its connection,
  # so a server that stops when its client goes away stops; the error says so, in case the server does not.
  def test_a_timed_out_request_closes_its_connection
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    closed = Queue.new
    stub = Thread.new do
      client = server.accept
      client.gets("\r\n\r\n") # the request line and headers; never answer
      loop do
        break closed << :eof if client.read_nonblock(4096, exception: false).nil?

        sleep 0.05
      end
    rescue IOError, SystemCallError
      closed << :reset
    ensure
      client&.close
    end

    err = assert_raises(Harness::ModelUnavailableError) do
      Harness::Model::Http.new.post("http://127.0.0.1:#{port}/v1/chat/completions", { "x" => 1 }, timeout: 1)
    end
    assert_match(/timed out after 1s; the connection was closed/, err.message)
    seen = Timeout.timeout(5) { closed.pop }
    assert_includes %i[eof reset], seen, "the server saw the client go away"
  ensure
    stub&.kill
    server&.close
  end
end
